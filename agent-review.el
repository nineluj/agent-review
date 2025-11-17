;;; agent-review.el --- AI-powered code review for git changes -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: nineluj
;; URL: https://github.com/nineluj/agent-review
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.7.1") (agent-shell "0.16.2"))

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

(defvar-local agent-review--current-issues nil
  "Current list of issues being displayed.")

(defvar-local agent-review--agent-config nil
  "Agent configuration used for the current review.")

(defvar-local agent-review--marked-issues nil
  "Hash table tracking marked issues (issue plist -> t).
Used to track which issues are selected for batch operations.")

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

(defvar-local agent-review--session-client nil
  "Current review session's ACP client.")

(defvar-local agent-review--session-id nil
  "Current review session ID.")

(defvar-local agent-review--session-response-text nil
  "Accumulated response text from current review session.")

(defvar agent-review--status-buffer nil
  "Buffer showing current review status.")

(defun agent-review--update-status-buffer (status)
  "Update the status buffer with STATUS message."
  (when (and agent-review--status-buffer
             (buffer-live-p agent-review--status-buffer))
    (with-current-buffer agent-review--status-buffer
      (let ((inhibit-read-only t))
        (setq tabulated-list-entries
              (list (list 'status (vector status))))
        (tabulated-list-print t)
        (goto-char (point-min)))))
  (force-mode-line-update t))

(defun agent-review--show-status-buffer (agent-name)
  "Create and display status buffer for AGENT-NAME."
  (let ((buffer (get-buffer-create "*Agent Review*")))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq tabulated-list-format [("Status" 0 nil)])
      (setq tabulated-list-padding 2)
      (tabulated-list-init-header)
      (setq tabulated-list-entries
            (list (list 'status (vector (format "Starting review with %s..." agent-name)))))
      (tabulated-list-print t)
      (goto-char (point-min)))
    (setq agent-review--status-buffer buffer)
    (display-buffer buffer)
    buffer))

(defun agent-review--cleanup-session (buffer)
  "Clean up review session in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when agent-review--session-id
        (ignore-errors
          (acp-send-notification
           :client agent-review--session-client
           :notification (acp-make-session-cancel-notification
                          :session-id agent-review--session-id
                          :reason "Review complete"))))
      (when agent-review--session-client
        (ignore-errors
          (acp-shutdown :client agent-review--session-client)))
      (setq agent-review--session-client nil
            agent-review--session-id nil
            agent-review--session-response-text nil))))

(defun agent-review--request-review-async (changes config on-complete)
  "Send CHANGES to agent using CONFIG and call ON-COMPLETE when done.
ON-COMPLETE is called with (response-text error) where error is nil on success."
  (let* ((work-buffer (generate-new-buffer " *agent-review-work*"))
         (client nil)
         (session-id nil))
    
    (with-current-buffer work-buffer
      (setq agent-review--session-response-text "")
      
      ;; Create client
      (setq client (funcall (alist-get :client-maker config) work-buffer))
      (setq agent-review--session-client client)
      
      ;; Subscribe to notifications to capture agent output
      (acp-subscribe-to-notifications
       :client client
       :buffer work-buffer
       :on-notification
       (lambda (notification)
         (when (buffer-live-p work-buffer)
           (with-current-buffer work-buffer
             (let-alist notification
               (when (equal .method "session/update")
                 (let ((update (alist-get 'update .params)))
                   (when (equal (alist-get 'sessionUpdate update) "agent_message_chunk")
                     (let-alist update
                       (setq agent-review--session-response-text
                             (concat agent-review--session-response-text .content.text)))))))))))
      
      ;; Subscribe to errors
      (acp-subscribe-to-errors
       :client client
       :buffer work-buffer
       :on-error
       (lambda (err)
         (let ((response agent-review--session-response-text))
           (agent-review--cleanup-session work-buffer)
           (kill-buffer work-buffer)
           (funcall on-complete nil (format "Agent error: %S" err)))))
      
      ;; Initialize (async)
      (agent-review--update-status-buffer "Handshaking with agent...")
      (message "Handshaking with agent...")
      (acp-send-request
       :client client
       :sync nil
       :request (acp-make-initialize-request
                 :protocol-version 1
                 :read-text-file-capability nil
                 :write-text-file-capability nil)
       :on-success
       (lambda (_result)
         (when (buffer-live-p work-buffer)
           ;; Create session (async)
           (agent-review--update-status-buffer "Creating session...")
           (message "Creating session...")
           (acp-send-request
            :client client
            :sync nil
            :request (acp-make-session-new-request
                      :cwd default-directory
                      :mcp-servers [])
            :on-success
            (lambda (session-response)
              (when (buffer-live-p work-buffer)
                (with-current-buffer work-buffer
                  (setq session-id (alist-get 'sessionId session-response))
                  (setq agent-review--session-id session-id)
                  
                  ;; Send prompt (async)
                  (agent-review--update-status-buffer "Agent is thinking...")
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
                     (when (buffer-live-p work-buffer)
                       (let ((response (with-current-buffer work-buffer
                                         agent-review--session-response-text)))
                         (agent-review--cleanup-session work-buffer)
                         (kill-buffer work-buffer)
                         (funcall on-complete response nil))))
                   :on-failure
                   (lambda (err)
                     (agent-review--cleanup-session work-buffer)
                     (kill-buffer work-buffer)
                     (funcall on-complete nil (format "Review request failed: %S" err)))))))
            :on-failure
            (lambda (err)
              (agent-review--cleanup-session work-buffer)
              (kill-buffer work-buffer)
              (funcall on-complete nil (format "Session creation failed: %S" err))))))
       :on-failure
       (lambda (err)
         (agent-review--cleanup-session work-buffer)
         (kill-buffer work-buffer)
         (funcall on-complete nil (format "Initialization failed: %S" err)))))))


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
    ("error" 'compilation-error)
    ("warning" 'compilation-warning)
    ("suggestion" 'compilation-info)
    (_ 'default)))

(defun agent-review--issue-marked-p (issue)
  "Return non-nil if ISSUE is marked."
  (and agent-review--marked-issues
       (gethash issue agent-review--marked-issues)))

(defun agent-review--format-entry (issue)
  "Format ISSUE as tabulated-list entry."
  (list issue
        (vector
         (if (agent-review--issue-marked-p issue) "*" " ")
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
  "Re-run the code review asynchronously using the same agent."
  (interactive)
  (if agent-review--agent-config
      (agent-review agent-review--agent-config)
    (call-interactively #'agent-review)))

;;; Selection Interface

(defun agent-review--init-marks ()
  "Initialize the marks hash table if not already created."
  (unless agent-review--marked-issues
    (setq agent-review--marked-issues (make-hash-table :test 'equal))))

(defun agent-review-mark ()
  "Mark the issue at point and move to the next line."
  (interactive)
  (when-let ((issue (tabulated-list-get-id)))
    (agent-review--init-marks)
    (puthash issue t agent-review--marked-issues)
    (tabulated-list-set-col 0 (if (agent-review--issue-marked-p issue) "*" " ") t)
    (forward-line 1)))

(defun agent-review-unmark ()
  "Unmark the issue at point and move to the next line."
  (interactive)
  (when-let ((issue (tabulated-list-get-id)))
    (when agent-review--marked-issues
      (remhash issue agent-review--marked-issues))
    (tabulated-list-set-col 0 (if (agent-review--issue-marked-p issue) "*" " ") t)
    (forward-line 1)))

(defun agent-review-mark-all ()
  "Mark all issues in the buffer."
  (interactive)
  (agent-review--init-marks)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when-let ((issue (tabulated-list-get-id)))
        (puthash issue t agent-review--marked-issues)
        (tabulated-list-set-col 0 "*" t))
      (forward-line 1)))
  (message "Marked all issues"))

(defun agent-review-unmark-all ()
  "Unmark all issues in the buffer."
  (interactive)
  (when agent-review--marked-issues
    (clrhash agent-review--marked-issues))
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (tabulated-list-get-id)
        (tabulated-list-set-col 0 " " t))
      (forward-line 1)))
  (message "Unmarked all issues"))

(defun agent-review--get-marked-issues ()
  "Return list of marked issues, or issue at point if none marked."
  (if (and agent-review--marked-issues
           (> (hash-table-count agent-review--marked-issues) 0))
      (let ((marked '()))
        (maphash (lambda (issue _v) (push issue marked))
                 agent-review--marked-issues)
        (nreverse marked))
    ;; No marks, return current issue if any
    (when-let ((issue (tabulated-list-get-id)))
      (list issue))))

(defun agent-review--format-issue-for-agent (issue)
  "Format ISSUE plist into agent-friendly text."
  (format "%s:%d [%s] %s"
          (plist-get issue :file)
          (plist-get issue :line)
          (upcase (plist-get issue :severity))
          (plist-get issue :description)))

(defun agent-review-copy-issues ()
  "Copy marked issues (or issue at point) in agent-friendly format.
The format is designed to be easily understood by AI agents for
implementing fixes."
  (interactive)
  (let ((issues (agent-review--get-marked-issues)))
    (if issues
        (let ((text (mapconcat #'agent-review--format-issue-for-agent
                               issues
                               "\n")))
          (kill-new text)
          (message "Copied %d issue%s to kill ring"
                   (length issues)
                   (if (= (length issues) 1) "" "s")))
      (message "No issues to copy"))))

(defun agent-review-send-to-agent-shell ()
  "Send marked issues (or issue at point) to agent-shell for implementation.
If no agent-shell is open in the current project, starts a new one."
  (interactive)
  (let ((issues (agent-review--get-marked-issues)))
    (if issues
        (let* ((prompt-header "Implement fixes for the following code review issues:\n\n")
               (issues-text (mapconcat #'agent-review--format-issue-for-agent
                                       issues
                                       "\n"))
               (full-text (concat prompt-header issues-text "\n")))
          ;; Check if an agent-shell exists, if not start one
          (condition-case err
              (progn
                (agent-shell-insert :text full-text)
                (message "Sent %d issue%s to agent-shell"
                         (length issues)
                         (if (= (length issues) 1) "" "s")))
            (error
             ;; No agent-shell available, start one and try again
             (if (y-or-n-p "No agent shell found. Start one? ")
                 (progn
                   (agent-shell-start :config (agent-shell-select-config
                                               :prompt "Select agent: "))
                   ;; Wait a moment for shell to initialize, then insert
                   (run-with-timer 1.0 nil
                                   (lambda (text)
                                     (condition-case err2
                                         (agent-shell-insert :text text)
                                       (error
                                        (message "Failed to send to agent-shell: %s" (error-message-string err2)))))
                                   full-text))
               (message "Cancelled")))))
      (message "No issues to send"))))

(defvar-keymap agent-review-mode-map
  :doc "Keymap for `agent-review-mode'."
  :parent tabulated-list-mode-map
  "RET" #'agent-review-jump-to-issue
  "g" #'agent-review-refresh
  "n" #'next-line
  "p" #'previous-line
  "m" #'agent-review-mark
  "u" #'agent-review-unmark
  "M" #'agent-review-mark-all
  "U" #'agent-review-unmark-all
  "W" #'agent-review-copy-issues
  "S" #'agent-review-send-to-agent-shell)

(define-derived-mode agent-review-mode tabulated-list-mode "Agent Review"
  "Major mode for displaying AI code review results.

\\{agent-review-mode-map}"
  (setq tabulated-list-format
        [("" 1 nil)  ; Mark column
         ("Severity" 10 t)
         ("File" 30 t)
         ("Line" 6 t :right-align t)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun agent-review--display-issues (issues agent-config)
  "Display ISSUES in a tabulated list buffer.
AGENT-CONFIG is stored for refresh operations."
  (let ((buffer (get-buffer-create "*Agent Review*")))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq agent-review--current-issues issues)
      (setq agent-review--agent-config agent-config)
      ;; Clear marks when displaying new results
      (setq agent-review--marked-issues nil)
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
  "Review current git changes using AI agent asynchronously.
With optional CONFIG, use that agent configuration.
Otherwise, prompt to select from `agent-shell-agent-configs'.

This function returns immediately and displays results when ready,
allowing Emacs to remain responsive during the review."
  (interactive)
  (let* ((agent-config (or config
                           (agent-shell-select-config
                            :prompt "Select agent for review: ")))
         (changes nil))
    
    ;; Collect changes synchronously (fast operation)
    (message "Collecting git changes...")
    (setq changes (agent-review--get-git-changes))
    
    ;; Show status buffer
    (agent-review--show-status-buffer
     (or (alist-get :mode-line-name agent-config)
         (alist-get :buffer-name agent-config)
         "agent"))
    
    ;; Request review asynchronously
    (message "Requesting review from %s..."
             (or (alist-get :mode-line-name agent-config)
                 (alist-get :buffer-name agent-config)
                 "agent"))
    
    (agent-review--request-review-async
     changes
     agent-config
     (lambda (response error-msg)
       (if error-msg
           (progn
             (message "Review failed: %s" error-msg)
             (when (buffer-live-p agent-review--status-buffer)
               (with-current-buffer agent-review--status-buffer
                 (let ((inhibit-read-only t))
                   (setq tabulated-list-format [("Status" 0 nil)])
                   (tabulated-list-init-header)
                   (setq tabulated-list-entries
                         (list (list 'status (vector (format "Review failed: %s" error-msg)))))
                   (tabulated-list-print t)
                   (setq agent-review--agent-config agent-config)
                   (goto-char (point-min))))))
         (let ((issues (agent-review--parse-issues response)))
           (if issues
               (agent-review--display-issues issues agent-config)
             (message "No issues found in review")
             (when (buffer-live-p agent-review--status-buffer)
               (with-current-buffer agent-review--status-buffer
                 (let ((inhibit-read-only t))
                   (setq tabulated-list-format [("Status" 0 nil)])
                   (tabulated-list-init-header)
                   (setq tabulated-list-entries
                         (list (list 'status (vector "Review complete: No issues found"))))
                   (tabulated-list-print t)
                   (setq agent-review--agent-config agent-config)
                   (goto-char (point-min))))))))))))

(provide 'agent-review)

;;; agent-review.el ends here
