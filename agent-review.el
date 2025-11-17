;;; agent-review.el --- AI-powered code review for git changes -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Julian Luj
;; URL: https://github.com/nineluj/agent-review
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.7.1") (agent-shell "0.17.2"))

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; agent-review.el provides AI-powered code review for git changes.
;; It uses acp.el and agent-shell configurations to analyze staged
;; and unstaged changes, displaying findings in a tabulated list.
;;
;; Usage:
;;   M-x agent-review
;;
;; This will:
;; 1. Collect your git changes (staged and unstaged)
;; 2. Send them to an AI agent for review
;; 3. Display issues in a navigable list
;; 4. Allow jumping to issue locations with RET
;;
;; Report issues at https://github.com/nineluj/agent-review/issues

;;; Code:

(require 'acp)
(require 'agent-shell)
(require 'tabulated-list)

(defgroup agent-review nil
  "AI-powered code review for git changes."
  :group 'tools
  :prefix "agent-review-")

(defcustom agent-review-git-executable "git"
  "Path to git executable."
  :type 'string
  :group 'agent-review)

(defvar agent-review--current-issues nil
  "Current list of issues being displayed.")

;;; Git Integration

(defun agent-review--check-git-repo ()
  "Check if current directory is in a git repository.
Signals an error if not."
  (unless (executable-find agent-review-git-executable)
    (error "Git executable not found: %s" agent-review-git-executable))
  (unless (zerop (call-process agent-review-git-executable nil nil nil
                               "rev-parse" "--git-dir"))
    (error "Not in a git repository")))

(defun agent-review--get-git-diff (args)
  "Get git diff using ARGS.
Returns diff as string or nil if no changes."
  (with-temp-buffer
    (let ((exit-code (apply #'call-process
                            agent-review-git-executable
                            nil t nil
                            "diff" args)))
      (if (zerop exit-code)
          (let ((content (buffer-string)))
            (if (string-empty-p (string-trim content))
                nil
              content))
        (error "Git diff failed with exit code %d" exit-code)))))

(defun agent-review--get-git-changes ()
  "Collect all git changes in the current repository.
Returns alist with :staged and :unstaged keys."
  (agent-review--check-git-repo)
  (let ((staged (agent-review--get-git-diff '("--cached")))
        (unstaged (agent-review--get-git-diff '())))
    (when (and (not staged) (not unstaged))
      (user-error "No git changes to review"))
    (list (cons :staged staged)
          (cons :unstaged unstaged))))

;;; Agent Integration

(defun agent-review--format-changes-for-prompt (changes)
  "Format CHANGES alist into text for agent prompt."
  (let ((parts '()))
    (when-let ((staged (alist-get :staged changes)))
      (push "=== Staged Changes ===\n\n" parts)
      (push staged parts)
      (push "\n\n" parts))
    (when-let ((unstaged (alist-get :unstaged changes)))
      (push "=== Unstaged Changes ===\n\n" parts)
      (push unstaged parts))
    (apply #'concat (nreverse parts))))

(defun agent-review--make-review-prompt (changes)
  "Create review prompt from CHANGES alist."
  (concat
   "Review the following git changes and identify issues. For each issue, provide:\n"
   "- File path\n"
   "- Line number (if applicable, otherwise use 1)\n"
   "- Severity (error/warning/suggestion)\n"
   "- Description\n\n"
   "Format your response as a list where each issue is on its own line in this format:\n"
   "FILE:LINE|SEVERITY|DESCRIPTION\n\n"
   "For example:\n"
   "src/main.el:42|error|Variable 'unused-var' is defined but never used\n"
   "lib/utils.el:15|warning|Function docstring is missing\n"
   "tests/test.el:8|suggestion|Consider adding edge case test\n\n"
   "Only output the issue lines, no other commentary.\n\n"
   "Git changes:\n\n"
   (agent-review--format-changes-for-prompt changes)))

(defvar agent-review--response-text nil
  "Buffer-local storage for agent response text.")

(defun agent-review--request-review (changes config)
  "Send CHANGES to agent using CONFIG and get review results.
Returns raw agent response text."
  (message "Initializing agent session...")
  (let* ((client (funcall (alist-get :client-maker config)
                          (current-buffer)))
         (session-id nil)
         (response-text "")
         (response-complete nil)
         (error-occurred nil))
    
    ;; Subscribe to notifications to capture agent output
    (acp-subscribe-to-notifications
     :client client
     :buffer (current-buffer)
     :on-notification
     (lambda (notification)
       (let-alist notification
         (when (equal .method "session/update")
           (let ((update (alist-get 'update .params)))
             (when (equal (alist-get 'sessionUpdate update) "agent_message_chunk")
               (let-alist update
                 (setq response-text (concat response-text .content.text)))))))))
    
    ;; Subscribe to errors
    (acp-subscribe-to-errors
     :client client
     :buffer (current-buffer)
     :on-error
     (lambda (err)
       (setq error-occurred t)
       (setq response-complete t)
       (message "Agent error: %S" err)))
    
    (unwind-protect
        (progn
          ;; Initialize
          (message "Handshaking with agent...")
          (acp-send-request
           :client client
           :sync t
           :request (acp-make-initialize-request
                     :protocol-version 1
                     :read-text-file-capability nil
                     :write-text-file-capability nil))
          
          ;; Create session
          (message "Creating session...")
          (let ((session-response
                 (acp-send-request
                  :client client
                  :sync t
                  :request (acp-make-session-new-request
                            :cwd default-directory
                            :mcp-servers []))))
            (setq session-id (alist-get 'sessionId session-response)))
          
          ;; Send prompt
          (message "Sending review request...")
          (acp-send-request
           :client client
           :sync nil
           :request (acp-make-session-prompt-request
                     :session-id session-id
                     :prompt (vector (list (cons 'type "text")
                                           (cons 'text (agent-review--make-review-prompt changes)))))
           :on-success
           (lambda (_result)
             (setq response-complete t))
           :on-failure
           (lambda (err)
             (setq error-occurred t)
             (setq response-complete t)
             (message "Review request failed: %S" err)))
          
          ;; Wait for response
          (while (not response-complete)
            (accept-process-output nil 0.1))
          
          (when error-occurred
            (error "Agent review failed"))
          
          response-text)
      
      ;; Cleanup
      (when session-id
        (ignore-errors
          (acp-send-notification
           :client client
           :notification (acp-make-session-cancel-notification
                          :session-id session-id
                          :reason "Review complete"))))
      (ignore-errors
        (acp-shutdown :client client)))))

;;; Response Parser

(defun agent-review--parse-issue-line (line)
  "Parse a single issue LINE.
Returns plist with :file :line :severity :description or nil if invalid."
  (when (string-match "^\\(.+?\\):\\([0-9]+\\)|\\(error\\|warning\\|suggestion\\)|\\(.+\\)$" line)
    (list :file (match-string 1 line)
          :line (string-to-number (match-string 2 line))
          :severity (match-string 3 line)
          :description (string-trim (match-string 4 line)))))

(defun agent-review--severity-priority (severity)
  "Return numeric priority for SEVERITY (lower is higher priority)."
  (pcase severity
    ("error" 1)
    ("warning" 2)
    ("suggestion" 3)
    (_ 4)))

(defun agent-review--parse-issues (response-text)
  "Parse agent RESPONSE-TEXT into structured issue list.
Returns list of issue plists sorted by file, then severity."
  (let ((lines (split-string response-text "\n" t))
        (issues '()))
    (dolist (line lines)
      (when-let ((issue (agent-review--parse-issue-line (string-trim line))))
        (push issue issues)))
    (sort (nreverse issues)
          (lambda (a b)
            (let ((file-a (plist-get a :file))
                  (file-b (plist-get b :file)))
              (if (string= file-a file-b)
                  ;; Same file, sort by severity
                  (< (agent-review--severity-priority (plist-get a :severity))
                     (agent-review--severity-priority (plist-get b :severity)))
                ;; Different files, sort alphabetically
                (string< file-a file-b)))))))

;;; Display Interface

(defun agent-review--severity-face (severity)
  "Return face for SEVERITY level."
  (pcase severity
    ("error" 'error)
    ("warning" 'warning)
    ("suggestion" 'info)
    (_ 'default)))

(defun agent-review--format-entry (issue)
  "Format ISSUE as tabulated-list entry."
  (list issue
        (vector
         (propertize (plist-get issue :severity)
                     'font-lock-face (agent-review--severity-face
                                      (plist-get issue :severity)))
         (plist-get issue :file)
         (propertize (number-to-string (plist-get issue :line))
                     'font-lock-face 'line-number)
         (plist-get issue :description))))

(defun agent-review-jump-to-issue ()
  "Jump to the issue at point."
  (interactive)
  (when-let* ((issue (tabulated-list-get-id))
              (file (plist-get issue :file))
              (line (plist-get issue :line)))
    (if (file-exists-p file)
        (progn
          (find-file-other-window file)
          (goto-char (point-min))
          (forward-line (1- line))
          (recenter)
          (pulse-momentary-highlight-one-line (point)))
      (message "File not found: %s" file))))

(defun agent-review-refresh ()
  "Re-run the code review."
  (interactive)
  (call-interactively #'agent-review))

(defvar-keymap agent-review-mode-map
  :doc "Keymap for `agent-review-mode'."
  :parent tabulated-list-mode-map
  "RET" #'agent-review-jump-to-issue
  "g" #'agent-review-refresh
  "n" #'next-line
  "p" #'previous-line)

(define-derived-mode agent-review-mode tabulated-list-mode "Agent Review"
  "Major mode for displaying AI code review results.

\\{agent-review-mode-map}"
  (setq tabulated-list-format
        [("Severity" 10 t)
         ("File" 30 t)
         ("Line" 6 t :right-align t)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun agent-review--display-issues (issues)
  "Display ISSUES in a tabulated list buffer."
  (let ((buffer (get-buffer-create "*Agent Review*")))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq agent-review--current-issues issues)
      (setq tabulated-list-entries
            (mapcar #'agent-review--format-entry issues))
      (tabulated-list-print t)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    (message "Review complete: %d issue%s found"
             (length issues)
             (if (= (length issues) 1) "" "s"))))

;;; Entry Point

;;;###autoload
(defun agent-review (&optional config)
  "Review current git changes using AI agent.
With optional CONFIG, use that agent configuration.
Otherwise, prompt to select from `agent-shell-agent-configs'."
  (interactive)
  (let* ((agent-config (or config
                           (agent-shell-select-config
                            :prompt "Select agent for review: ")))
         (changes nil)
         (response nil)
         (issues nil))
    
    ;; Collect changes
    (message "Collecting git changes...")
    (setq changes (agent-review--get-git-changes))
    
    ;; Request review
    (message "Requesting review from %s..."
             (or (alist-get :mode-line-name agent-config)
                 (alist-get :buffer-name agent-config)
                 "agent"))
    (setq response (agent-review--request-review changes agent-config))
    
    ;; Parse and display
    (setq issues (agent-review--parse-issues response))
    
    (if issues
        (agent-review--display-issues issues)
      (message "No issues found in review"))))

(provide 'agent-review)

;;; agent-review.el ends here
