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

(defun agent-review--project-name ()
  "Return the current project name.
Uses projectile, project.el, or falls back to the directory name."
  (or (when-let* (((boundp 'projectile-mode))
                  projectile-mode
                  ((fboundp 'projectile-project-name))
                  (root (projectile-project-root)))
        (projectile-project-name root))
      (when-let* (((fboundp 'project-name))
                  (project (project-current)))
        (project-name project))
      (file-name-nondirectory
       (directory-file-name default-directory))))

(defun agent-review--buffer-name ()
  "Return the review buffer name for the current project."
  (format "*Agent Review @ %s*" (agent-review--project-name)))

(defun agent-review--diagnostic-buffer-name ()
  "Return the diagnostic buffer name for the current project."
  (format "*Agent Review Diagnostic @ %s*" (agent-review--project-name)))

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

(defun agent-review--changed-files (diff-text)
  "Extract list of changed file paths from DIFF-TEXT."
  (let ((files '()))
    (with-temp-buffer
      (insert diff-text)
      (goto-char (point-min))
      (while (re-search-forward "^\\+\\+\\+ b/\\(.+\\)$" nil t)
        (let ((file (match-string 1)))
          (unless (equal file "/dev/null")
            (push file files)))))
    (delete-dups (nreverse files))))

(defun agent-review--read-file-with-line-numbers (file)
  "Read FILE and return its contents with line numbers prepended.
Each line is formatted as \"NNNN: content\".
Returns nil if the file does not exist or is not readable."
  (when (and (file-exists-p file) (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((lines (split-string (buffer-string) "\n"))
            (numbered '())
            (n 1))
        (dolist (line lines)
          (push (format "%4d: %s" n line) numbered)
          (setq n (1+ n)))
        (mapconcat #'identity (nreverse numbered) "\n")))))

(defun agent-review--format-changed-files (changes)
  "Collect full contents of files referenced in CHANGES.
Returns a string with each file preceded by a header and numbered lines."
  (let ((files '()))
    (when-let ((staged (alist-get :staged changes)))
      (setq files (append files (agent-review--changed-files staged))))
    (when-let ((unstaged (alist-get :unstaged changes)))
      (setq files (append files (agent-review--changed-files unstaged))))
    (setq files (delete-dups files))
    (let ((parts '()))
      (dolist (file files)
        (when-let ((content (agent-review--read-file-with-line-numbers file)))
          (push (format "=== File: %s ===\n" file) parts)
          (push content parts)
          (push "\n\n" parts)))
      (when parts
        (apply #'concat (nreverse parts))))))

(defun agent-review--format-changes-for-prompt (changes)
  "Format CHANGES alist into text for agent prompt."
  (let ((parts '()))
    (when-let ((staged (alist-get :staged changes)))
      (push "=== Staged Changes (diff) ===\n\n" parts)
      (push staged parts)
      (push "\n\n" parts))
    (when-let ((unstaged (alist-get :unstaged changes)))
      (push "=== Unstaged Changes (diff) ===\n\n" parts)
      (push unstaged parts)
      (push "\n\n" parts))
    (when-let ((file-contents (agent-review--format-changed-files changes)))
      (push "=== Full File Contents (with line numbers) ===\n\n" parts)
      (push file-contents parts))
    (apply #'concat (nreverse parts))))

(defun agent-review--load-language-prompt (language)
  "Load the review prompt file for LANGUAGE.
Reads from the languages/ directory relative to the package install path.
Falls back to \"other.txt\" if the language file does not exist."
  (let* ((pkg-dir (file-name-directory (locate-library "agent-review")))
         (lang-file (expand-file-name (format "languages/%s.md" language) pkg-dir))
         (fallback (expand-file-name "languages/other.md" pkg-dir))
         (file (if (file-exists-p lang-file) lang-file fallback)))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun agent-review--make-review-prompt (changes detected-language)
  "Create review prompt from CHANGES alist for DETECTED-LANGUAGE."
  (concat
   (agent-review--load-language-prompt detected-language)
   "\n\n"
   "Review the following git changes and identify issues.\n\n"
   "You are given two things:\n"
   "1. Git diffs showing what changed\n"
   "2. Full file contents with line numbers (each line prefixed with its number, e.g. \"  42: code here\")\n\n"
   "LINE NUMBER INSTRUCTIONS:\n"
   "Use the line numbers from the \"Full File Contents\" section to determine the correct line.\n"
   "Find the relevant code in the numbered file listing and report that line number.\n"
   "You MUST report accurate line numbers. Do NOT default to 1.\n\n"
   "For each issue, provide:\n"
   "- File path (from the diff +++ b/PATH header)\n"
   "- Line number (from the numbered file contents)\n"
   "- Severity (error/warning/suggestion)\n"
   "- Short description (max 60 chars, very brief summary)\n"
   "- Diagnostic (full explanation with reasoning, best practice references, and fix guidance. Use markdown formatting.)\n\n"
   "Format your response as a list where each issue is on its own line in this EXACT format:\n"
   "FILE:LINE|SEVERITY|SHORT_DESCRIPTION|DIAGNOSTIC\n\n"
   "The SHORT_DESCRIPTION must be very brief (under 60 characters).\n"
   "The DIAGNOSTIC should be a thorough explanation. Use diagrams if they help illustrate the concept.\n"
   "Keep each issue on a SINGLE line — do not use literal newlines inside the DIAGNOSTIC field.\n"
   "Use \\n for line breaks within the DIAGNOSTIC field.\n\n"
   "For example:\n"
   "src/main.el:42|error|Unused variable 'unused-var'|The variable `unused-var` is defined on line 42 but never referenced in the function body.\\nThis is likely a leftover from a refactor. Remove it to keep the code clean.\\n\\n**Best practice**: Run a linter to catch unused bindings automatically.\n"
   "lib/utils.el:15|warning|Missing docstring|Public function `parse-input` lacks a docstring.\\nAll public API functions should document their parameters and return values.\\n\\n**Fix**: Add a docstring describing the expected input format and return type.\n"
   "tests/test.el:8|suggestion|Add edge case test|The test suite covers the happy path but misses boundary conditions.\\nConsider adding tests for empty input, nil values, and maximum-length strings.\n\n"
   "Only output the issue lines, no other commentary.\n\n"
   "Git changes:\n\n"
   (agent-review--format-changes-for-prompt changes)))

(defconst agent-review--known-languages '("python" "clojure" "typescript")
  "List of programming languages with specific review prompts.")

(defconst agent-review--ignored-extensions '("org" "md" "txt" "json" "yaml" "yml" "toml" "ini" "cfg" "conf" "lock")
  "File extensions to ignore when sampling code for language detection.")

(defun agent-review--ignored-file-p (filename)
  "Return non-nil if FILENAME should be ignored for language detection.
Ignores dotfiles, and files with extensions in `agent-review--ignored-extensions'."
  (let ((base (file-name-nondirectory filename)))
    (or (string-prefix-p "." base)
        (member (file-name-extension base) agent-review--ignored-extensions))))

(defun agent-review--extract-diff-sample (diff-text)
  "Extract file paths and a small code sample from DIFF-TEXT.
Returns a compact string with diff headers and up to 20 code lines
per file, filtering out ignored files."
  (when diff-text
    (let ((lines (split-string diff-text "\n"))
          (parts '())
          (current-file nil)
          (current-file-ignored nil)
          (code-lines-count 0)
          (max-code-lines 20))
      (dolist (line lines)
        (cond
         ;; diff header — extract file path
         ((string-match "^diff --git a/.+ b/\\(.+\\)$" line)
          (setq current-file (match-string 1 line))
          (setq current-file-ignored (agent-review--ignored-file-p current-file))
          (setq code-lines-count 0)
          (unless current-file-ignored
            (push (format "--- %s ---" current-file) parts)))
         ;; code lines (+ or -) — collect a sample
         ((and (not current-file-ignored)
               (< code-lines-count max-code-lines)
               (string-match-p "^[+-][^+-]" line))
          (push line parts)
          (setq code-lines-count (1+ code-lines-count)))))
      (when parts
        (mapconcat #'identity (nreverse parts) "\n")))))

(defun agent-review--make-language-detection-prompt (changes)
  "Create a prompt to detect the programming language from CHANGES.
Sends only file paths and a small code sample to keep the request fast."
  (let* ((staged-sample (agent-review--extract-diff-sample
                         (alist-get :staged changes)))
         (unstaged-sample (agent-review--extract-diff-sample
                           (alist-get :unstaged changes)))
         (sample (string-trim
                  (concat (or staged-sample "") "\n" (or unstaged-sample "")))))
    (concat
     "Identify the primary programming language used in these code changes.\n"
     "You MUST respond with exactly one word, no punctuation, no explanation.\n"
     "Choose from: python, clojure, typescript, other\n"
     "If the changes contain multiple languages, pick the dominant one.\n"
     "If it does not clearly match python, clojure, or typescript, respond with: other\n\n"
     sample)))

(defun agent-review--parse-language-response (response-text)
  "Parse RESPONSE-TEXT into a known language string.
Returns one of \"python\", \"clojure\", \"typescript\", or \"other\"."
  (let ((lang (downcase (string-trim response-text))))
    (if (member lang agent-review--known-languages)
        lang
      "other")))

(defvar-local agent-review--session-client nil
  "Current review session's ACP client.")

(defvar-local agent-review--session-id nil
  "Current review session ID.")

(defvar-local agent-review--session-response-text nil
  "Accumulated response text from current review session.")

(defvar-local agent-review--diagnostic-buffer-name nil
  "Buffer name for the diagnostic buffer associated with this review.")

(defvar-local agent-review--progress-timer nil
  "Timer for updating progress feedback in this buffer.")

(defvar-local agent-review--progress-start-time nil
  "Time when the review in this buffer started.")

(defvar-local agent-review--progress-phase nil
  "Current phase description for progress display in this buffer.")

(defconst agent-review--spinner-frames '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Spinner animation frames.")

(defvar-local agent-review--spinner-index 0
  "Current spinner frame index for this buffer.")

(defun agent-review--format-elapsed (buffer)
  "Format elapsed time since review started in BUFFER."
  (if (and (buffer-live-p buffer)
           (buffer-local-value 'agent-review--progress-start-time buffer))
      (let ((elapsed (float-time
                      (time-subtract
                       (current-time)
                       (buffer-local-value 'agent-review--progress-start-time buffer)))))
        (format "%ds" (truncate elapsed)))
    ""))

(defun agent-review--update-status-buffer (status-buffer status)
  "Update STATUS-BUFFER with STATUS message.
Also sets the current progress phase for the timer to display."
  (when (buffer-live-p status-buffer)
    (with-current-buffer status-buffer
      (setq agent-review--progress-phase status)
      (let ((elapsed (agent-review--format-elapsed status-buffer))
            (spinner (nth (% agent-review--spinner-index
                             (length agent-review--spinner-frames))
                          agent-review--spinner-frames))
            (inhibit-read-only t))
        (setq tabulated-list-entries
              (list (list 'status
                          (vector (format "%s %s  [%s]" spinner status elapsed)))))
        (tabulated-list-print t)
        (goto-char (point-min)))))
  (force-mode-line-update t))

(defun agent-review--progress-tick (status-buffer)
  "Called by timer to update spinner and elapsed time in STATUS-BUFFER."
  (when (buffer-live-p status-buffer)
    (with-current-buffer status-buffer
      (setq agent-review--spinner-index (1+ agent-review--spinner-index))
      (when agent-review--progress-phase
        (agent-review--update-status-buffer status-buffer agent-review--progress-phase)))))

(defun agent-review--start-progress (status-buffer)
  "Start the progress timer for STATUS-BUFFER."
  (agent-review--stop-progress status-buffer)
  (with-current-buffer status-buffer
    (setq agent-review--progress-start-time (current-time))
    (setq agent-review--spinner-index 0)
    (setq agent-review--progress-timer
          (run-with-timer 0.3 0.3 #'agent-review--progress-tick status-buffer))))

(defun agent-review--stop-progress (status-buffer)
  "Stop the progress timer for STATUS-BUFFER."
  (when (buffer-live-p status-buffer)
    (with-current-buffer status-buffer
      (when agent-review--progress-timer
        (cancel-timer agent-review--progress-timer)
        (setq agent-review--progress-timer nil))
      (setq agent-review--progress-phase nil)
      (setq agent-review--progress-start-time nil))))

(defun agent-review--show-status-buffer (review-buffer-name agent-name)
  "Create and display status buffer named REVIEW-BUFFER-NAME for AGENT-NAME.
Returns the created buffer."
  (let ((buffer (get-buffer-create review-buffer-name)))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq tabulated-list-format [("Status" 0 nil)])
      (setq tabulated-list-padding 2)
      (tabulated-list-init-header)
      (setq tabulated-list-entries
            (list (list 'status (vector (format "Starting review with %s..." agent-name)))))
      (tabulated-list-print t)
      (goto-char (point-min)))
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

(defun agent-review--request-review-async (changes config status-buffer on-complete)
  "Send CHANGES to agent using CONFIG and call ON-COMPLETE when done.
STATUS-BUFFER is the buffer to update with progress information.
ON-COMPLETE is called with (response-text detected-language error)
where error is nil on success.  The review runs in two turns:
first detecting the programming language, then sending the review prompt."
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
           (funcall on-complete nil nil (format "Agent error: %S" err)))))
      
      ;; Initialize (async)
      (agent-review--update-status-buffer status-buffer "Handshaking with agent...")
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
           (agent-review--update-status-buffer status-buffer "Creating session...")
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
                  
                  ;; Turn 1: detect programming language
                  (agent-review--update-status-buffer status-buffer "Detecting language...")
                  (message "Detecting programming language...")
                  (acp-send-request
                   :client client
                   :sync nil
                   :request (acp-make-session-prompt-request
                             :session-id session-id
                             :prompt (vector (list (cons 'type "text")
                                                   (cons 'text (agent-review--make-language-detection-prompt changes)))))
                   :on-success
                   (lambda (_result)
                     (when (buffer-live-p work-buffer)
                       (let ((detected-language
                              (with-current-buffer work-buffer
                                (agent-review--parse-language-response
                                 agent-review--session-response-text))))
                         ;; Reset accumulated text for turn 2
                         (with-current-buffer work-buffer
                           (setq agent-review--session-response-text ""))
                         ;; Turn 2: send review prompt
                         (agent-review--update-status-buffer
                          status-buffer (format "Reviewing %s code..." detected-language))
                         (message "Language: %s — sending review request..." detected-language)
                         (acp-send-request
                          :client client
                          :sync nil
                          :request (acp-make-session-prompt-request
                                    :session-id session-id
                                    :prompt (vector (list (cons 'type "text")
                                                          (cons 'text (agent-review--make-review-prompt changes detected-language)))))
                          :on-success
                          (lambda (_result)
                            (when (buffer-live-p work-buffer)
                              (let ((response (with-current-buffer work-buffer
                                                agent-review--session-response-text)))
                                (agent-review--cleanup-session work-buffer)
                                (kill-buffer work-buffer)
                                (funcall on-complete response detected-language nil))))
                          :on-failure
                          (lambda (err)
                            (agent-review--cleanup-session work-buffer)
                            (kill-buffer work-buffer)
                            (funcall on-complete nil nil (format "Review request failed: %S" err)))))))
                   :on-failure
                   (lambda (err)
                     (agent-review--cleanup-session work-buffer)
                     (kill-buffer work-buffer)
                     (funcall on-complete nil nil (format "Language detection failed: %S" err)))))))
            :on-failure
            (lambda (err)
              (agent-review--cleanup-session work-buffer)
              (kill-buffer work-buffer)
              (funcall on-complete nil nil (format "Session creation failed: %S" err))))))
       :on-failure
       (lambda (err)
         (agent-review--cleanup-session work-buffer)
         (kill-buffer work-buffer)
         (funcall on-complete nil nil (format "Initialization failed: %S" err)))))))


;;; Response Parser

(defun agent-review--unescape-diagnostic (text)
  "Unescape literal \\n sequences in TEXT to actual newlines."
  (replace-regexp-in-string "\\\\n" "\n" text))

(defun agent-review--parse-issue-line (line)
  "Parse a single issue LINE.
Returns plist with :file :line :severity :short-description :diagnostic
or nil if invalid.  The format is FILE:LINE|SEVERITY|SHORT_DESCRIPTION|DIAGNOSTIC."
  (when (string-match "^\\(.+?\\):\\([0-9]+\\)|\\(error\\|warning\\|suggestion\\)|\\([^|]+\\)|\\(.+\\)$" line)
    (list :file (match-string 1 line)
          :line (string-to-number (match-string 2 line))
          :severity (match-string 3 line)
          :short-description (string-trim (match-string 4 line))
          :diagnostic (agent-review--unescape-diagnostic
                       (string-trim (match-string 5 line))))))

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
         (propertize (format "%5d" (plist-get issue :line))
                     'font-lock-face 'line-number)
         (plist-get issue :short-description))))

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
  (format "%s:%d [%s] %s\n\nDiagnostic:\n%s"
          (plist-get issue :file)
          (plist-get issue :line)
          (upcase (plist-get issue :severity))
          (plist-get issue :short-description)
          (plist-get issue :diagnostic)))

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

;;; Diagnostic Buffer

(defvar-local agent-review-diagnostic--issue nil
  "The issue plist displayed in this diagnostic buffer.")

(defvar-local agent-review-diagnostic--issues nil
  "Full list of issues for n/p navigation.")

(defvar-local agent-review-diagnostic--index 0
  "Current index in the issues list.")

(defun agent-review-diagnostic--hard-wrap (start end col)
  "Hard-wrap text between START and END at column COL.
Breaks lines at word boundaries.  Preserves existing newlines."
  (save-excursion
    (goto-char start)
    (while (< (point) (min end (point-max)))
      (let ((line-start (point))
            (line-end (line-end-position)))
        (when (> (- line-end line-start) col)
          (goto-char (+ line-start col))
          ;; Back up to a word boundary
          (if (re-search-backward "[ \t]" line-start t)
              (progn
                (forward-char 1)
                (unless (= (point) line-start)
                  (delete-horizontal-space)
                  (insert "\n")))
            ;; No space found, force break at col
            (goto-char (+ line-start col))
            (insert "\n")))
        (forward-line 1)))))

(defun agent-review-diagnostic--fontify-markdown (start end)
  "Apply markdown font-lock to the region between START and END.
Uses markdown-mode's font-lock keywords in a temp buffer to
compute faces, then copies them to the current buffer."
  (when (fboundp 'markdown-mode)
    (let ((text (buffer-substring-no-properties start end))
          (fontified nil))
      (with-temp-buffer
        (insert text)
        (delay-mode-hooks (markdown-mode))
        (font-lock-ensure)
        (setq fontified (buffer-string)))
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert fontified)))))

(defun agent-review-diagnostic--render (issue)
  "Render ISSUE into the current diagnostic buffer."
  (let ((inhibit-read-only t)
        (file (plist-get issue :file))
        (line (plist-get issue :line))
        (severity (plist-get issue :severity))
        (short-desc (plist-get issue :short-description))
        (diagnostic (plist-get issue :diagnostic)))
    (erase-buffer)
    ;; Header
    (insert (propertize (format "%s:%d" file line)
                        'face 'bold)
            "\n")
    (insert (propertize (upcase severity)
                        'face (agent-review--severity-face severity))
            "  "
            (propertize short-desc 'face 'italic)
            "\n")
    ;; Separator
    (insert (propertize (make-string 72 ?─) 'face 'shadow) "\n\n")
    ;; Diagnostic body (hard-wrapped at column 80, markdown fontified)
    (let ((diag-start (point)))
      (insert diagnostic)
      (agent-review-diagnostic--hard-wrap diag-start (point) 80)
      (agent-review-diagnostic--fontify-markdown diag-start (point))
      (insert "\n\n"))
    ;; Footer with keybinding hints
    (insert (propertize (make-string 72 ?─) 'face 'shadow) "\n")
    (let ((hint (lambda (key desc)
                  (concat (propertize key 'face 'help-key-binding)
                          " " (propertize desc 'face 'shadow) "  "))))
      (insert (funcall hint "RET" "jump to file")
              (funcall hint "I" "investigate")
              (funcall hint "S" "fix in agent-shell")
              (funcall hint "W" "copy")
              (funcall hint "n/p" "navigate")
              (funcall hint "q" "quit")))
    (goto-char (point-min))
    (setq agent-review-diagnostic--issue issue)))

(defun agent-review-diagnostic-jump-to-issue ()
  "Jump to the file location of the current diagnostic issue."
  (interactive)
  (when-let* ((issue agent-review-diagnostic--issue)
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

(defun agent-review-diagnostic-send-to-agent-shell ()
  "Send the current diagnostic issue to agent-shell."
  (interactive)
  (when-let ((issue agent-review-diagnostic--issue))
    (let* ((prompt-header "Implement a fix for the following code review issue:\n\n")
           (issue-text (agent-review--format-issue-for-agent issue))
           (full-text (concat prompt-header issue-text "\n")))
      (condition-case nil
          (progn
            (agent-shell-insert :text full-text)
            (message "Sent issue to agent-shell"))
        (error
         (if (y-or-n-p "No agent shell found. Start one? ")
             (progn
               (agent-shell-start :config (agent-shell-select-config
                                            :prompt "Select agent: "))
               (run-with-timer 1.0 nil
                               (lambda (text)
                                 (condition-case err
                                     (agent-shell-insert :text text)
                                   (error
                                    (message "Failed to send to agent-shell: %s"
                                             (error-message-string err)))))
                               full-text))
           (message "Cancelled")))))))

(defun agent-review-diagnostic-copy-issue ()
  "Copy the current diagnostic issue to the kill ring."
  (interactive)
  (when-let ((issue agent-review-diagnostic--issue))
    (kill-new (agent-review--format-issue-for-agent issue))
    (message "Copied issue to kill ring")))

(defun agent-review-diagnostic-next ()
  "Show the next issue in the diagnostic buffer."
  (interactive)
  (when agent-review-diagnostic--issues
    (let ((new-index (mod (1+ agent-review-diagnostic--index)
                          (length agent-review-diagnostic--issues))))
      (setq agent-review-diagnostic--index new-index)
      (agent-review-diagnostic--render
       (nth new-index agent-review-diagnostic--issues))
      (message "Issue %d/%d"
               (1+ new-index) (length agent-review-diagnostic--issues)))))

(defun agent-review-diagnostic-prev ()
  "Show the previous issue in the diagnostic buffer."
  (interactive)
  (when agent-review-diagnostic--issues
    (let ((new-index (mod (1- agent-review-diagnostic--index)
                          (length agent-review-diagnostic--issues))))
      (setq agent-review-diagnostic--index new-index)
      (agent-review-diagnostic--render
       (nth new-index agent-review-diagnostic--issues))
      (message "Issue %d/%d"
               (1+ new-index) (length agent-review-diagnostic--issues)))))

(defun agent-review-diagnostic-investigate ()
  "Ask a question about the current issue in agent-shell.
Prompts for a message, then sends it to agent-shell with the
diagnostic appended as context."
  (interactive)
  (when-let ((issue agent-review-diagnostic--issue))
    (let* ((message-text (read-string "Investigate: "))
           (context (agent-review--format-issue-for-agent issue))
           (full-text (concat message-text
                              "\n\nContext from code review:\n\n"
                              context "\n")))
      (condition-case nil
          (progn
            (agent-shell-insert :text full-text)
            (message "Sent to agent-shell"))
        (error
         (if (y-or-n-p "No agent shell found. Start one? ")
             (progn
               (agent-shell-start :config (agent-shell-select-config
                                            :prompt "Select agent: "))
               (run-with-timer 1.0 nil
                               (lambda (text)
                                 (condition-case err
                                     (agent-shell-insert :text text)
                                   (error
                                    (message "Failed to send to agent-shell: %s"
                                             (error-message-string err)))))
                               full-text))
           (message "Cancelled")))))))

(defvar-keymap agent-review-diagnostic-mode-map
  :doc "Keymap for `agent-review-diagnostic-mode'."
  :parent special-mode-map
  "RET" #'agent-review-diagnostic-jump-to-issue
  "o" #'agent-review-diagnostic-jump-to-issue
  "I" #'agent-review-diagnostic-investigate
  "S" #'agent-review-diagnostic-send-to-agent-shell
  "W" #'agent-review-diagnostic-copy-issue
  "n" #'agent-review-diagnostic-next
  "p" #'agent-review-diagnostic-prev
  "q" #'quit-window)

(define-derived-mode agent-review-diagnostic-mode special-mode "AR-Diagnostic"
  "Major mode for displaying a full diagnostic for a review issue.

\\{agent-review-diagnostic-mode-map}")

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-review-diagnostic-mode 'normal)
  (evil-define-key 'normal agent-review-diagnostic-mode-map
    (kbd "RET") #'agent-review-diagnostic-jump-to-issue
    "o"  #'agent-review-diagnostic-jump-to-issue
    "I"  #'agent-review-diagnostic-investigate
    "S"  #'agent-review-diagnostic-send-to-agent-shell
    "W"  #'agent-review-diagnostic-copy-issue
    "n"  #'agent-review-diagnostic-next
    "p"  #'agent-review-diagnostic-prev
    "q"  #'quit-window))

(defun agent-review-show-diagnostic ()
  "Show the full diagnostic for the issue at point.
Opens the *Agent Review Diagnostic* buffer in a side window."
  (interactive)
  (when-let* ((issue (tabulated-list-get-id))
              (issues agent-review--current-issues)
              (index (seq-position issues issue #'equal)))
    (let ((buffer (get-buffer-create (or agent-review--diagnostic-buffer-name
                                        "*Agent Review Diagnostic*"))))
      (with-current-buffer buffer
        (agent-review-diagnostic-mode)
        (setq agent-review-diagnostic--issues issues)
        (setq agent-review-diagnostic--index index)
        (agent-review-diagnostic--render issue))
      (display-buffer-in-side-window buffer '((side . bottom)
                                               (window-height . 0.4))))))

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
  "S" #'agent-review-send-to-agent-shell
  "e" #'agent-review-show-diagnostic
  "l" #'agent-review-list-reviews)

(define-derived-mode agent-review-mode tabulated-list-mode "Agent Review"
  "Major mode for displaying AI code review results.

\\{agent-review-mode-map}"
  (setq tabulated-list-format
        [("" 1 nil)  ; Mark column
         ("Severity" 10 t)
         ("File" 30 t)
         ("Line" 6 t :right-align t)
         ("Issue" 0 nil)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-review-mode 'normal)
  (evil-define-key 'normal agent-review-mode-map
    (kbd "RET") #'agent-review-jump-to-issue
    "g"  nil  ; avoid shadowing evil gg/G
    "gr" #'agent-review-refresh
    "n"  #'next-line
    "p"  #'previous-line
    "m"  #'agent-review-mark
    "u"  #'agent-review-unmark
    "M"  #'agent-review-mark-all
    "U"  #'agent-review-unmark-all
    "W"  #'agent-review-copy-issues
    "S"  #'agent-review-send-to-agent-shell
    "e"  #'agent-review-show-diagnostic
    "l"  #'agent-review-list-reviews))

(defun agent-review--display-issues (issues agent-config review-buffer-name diagnostic-buffer-name)
  "Display ISSUES in a tabulated list buffer named REVIEW-BUFFER-NAME.
AGENT-CONFIG is stored for refresh operations.
DIAGNOSTIC-BUFFER-NAME is stored for showing diagnostics."
  (let ((buffer (get-buffer-create review-buffer-name)))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq agent-review--current-issues issues)
      (setq agent-review--agent-config agent-config)
      (setq agent-review--diagnostic-buffer-name diagnostic-buffer-name)
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

;;; Review List

(defun agent-review--buffer-status (buffer)
  "Return a status string for an Agent Review BUFFER."
  (with-current-buffer buffer
    (cond
     ;; Still processing — progress timer is active
     (agent-review--progress-timer
      (format "reviewing... [%s]" (agent-review--format-elapsed buffer)))
     ;; Has issues displayed
     (agent-review--current-issues
      (format "%d issue%s"
              (length agent-review--current-issues)
              (if (= (length agent-review--current-issues) 1) "" "s")))
     ;; Buffer exists in review mode but no issues
     (t "idle"))))

(defun agent-review--collect-review-buffers ()
  "Return list of all live Agent Review buffers with metadata.
Each entry is (buffer name status)."
  (let ((results '()))
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (with-current-buffer buf
                   (derived-mode-p 'agent-review-mode)))
        (push (list buf
                    (buffer-name buf)
                    (agent-review--buffer-status buf))
              results)))
    (nreverse results)))

(defun agent-review-list-reviews-jump ()
  "Switch to the review buffer at point."
  (interactive)
  (when-let ((entry (tabulated-list-get-id)))
    (select-window
     (display-buffer entry '(display-buffer-use-some-window
                             ((inhibit-same-window . t)))))))

(defun agent-review-list-reviews-mouse-jump (event)
  "Switch to the review buffer clicked with EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (goto-char (posn-point (event-start event)))
    (agent-review-list-reviews-jump)))

(defun agent-review-list-reviews-revert (&rest _args)
  "Refresh the review list entries."
  (let ((reviews (agent-review--collect-review-buffers)))
    (setq tabulated-list-entries
          (mapcar (lambda (entry)
                    (let ((buf (nth 0 entry))
                          (name (nth 1 entry))
                          (status (nth 2 entry)))
                      (list buf
                            (vector (propertize name
                                                'mouse-face 'highlight
                                                'help-echo "mouse-1: switch to this review")
                                    (propertize status 'face
                                                (cond
                                                 ((string-prefix-p "reviewing" status)
                                                  'compilation-warning)
                                                 ((string-suffix-p "issues" status)
                                                  'compilation-error)
                                                 (t 'shadow)))))))
                  reviews))))

(defvar agent-review-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'agent-review-list-reviews-jump)
    (define-key map [mouse-1] #'agent-review-list-reviews-mouse-jump)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `agent-review-list-mode'.")

(define-derived-mode agent-review-list-mode tabulated-list-mode "AR-List"
  "Major mode for listing all Agent Review buffers."
  (setq tabulated-list-format
        [("Buffer" 40 t)
         ("Status" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq revert-buffer-function #'agent-review-list-reviews-revert)
  (tabulated-list-init-header))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-review-list-mode 'normal)
  (evil-define-key 'normal agent-review-list-mode-map
    (kbd "RET") #'agent-review-list-reviews-jump
    "q" #'quit-window))

;;;###autoload
(defun agent-review-list-reviews ()
  "List all Agent Review buffers and their statuses.
Displays in a side window for easy navigation."
  (interactive)
  (let ((reviews (agent-review--collect-review-buffers))
        (buffer (get-buffer-create "*Agent Reviews*")))
    (if (null reviews)
        (message "No Agent Review buffers open")
      (with-current-buffer buffer
        (agent-review-list-mode)
        (agent-review-list-reviews-revert)
        (tabulated-list-print t)
        (goto-char (point-min)))
      (display-buffer-in-side-window buffer '((side . bottom)
                                              (window-height . 0.3))))))

;;; Entry Point

;;;###autoload
(defun agent-review (&optional config)
  "Review current git changes using AI agent asynchronously.
With optional CONFIG, use that agent configuration.
Otherwise, prompt to select from `agent-shell-agent-configs'.

This function returns immediately and displays results when ready,
allowing Emacs to remain responsive during the review."
  (interactive)
  (unless (condition-case nil
              (agent-shell-project-buffers)
            (error nil))
    (user-error "No agent-shell session for this project.  Start one first with M-x agent-shell"))
  (let* ((agent-config (or config
                           (agent-shell-select-config
                            :prompt "Select agent for review: ")))
         (review-buffer-name (agent-review--buffer-name))
         (diagnostic-buffer-name (agent-review--diagnostic-buffer-name))
         (changes (progn
                    (message "Collecting git changes...")
                    (agent-review--get-git-changes)))
         (status-buffer
          (agent-review--show-status-buffer
           review-buffer-name
           (or (alist-get :mode-line-name agent-config)
               (alist-get :buffer-name agent-config)
               "agent"))))

    ;; Start progress feedback
    (agent-review--start-progress status-buffer)

    ;; Request review asynchronously
    (message "Requesting review from %s..."
             (or (alist-get :mode-line-name agent-config)
                 (alist-get :buffer-name agent-config)
                 "agent"))
    
    (agent-review--request-review-async
     changes
     agent-config
     status-buffer
     (lambda (response detected-language error-msg)
       (agent-review--stop-progress status-buffer)
       (if error-msg
           (progn
             (message "Review failed: %s" error-msg)
             (when (buffer-live-p status-buffer)
               (with-current-buffer status-buffer
                 (let ((inhibit-read-only t))
                   (setq tabulated-list-format [("Status" 0 nil)])
                   (tabulated-list-init-header)
                   (setq tabulated-list-entries
                         (list (list 'status (vector (format "Review failed: %s" error-msg)))))
                   (tabulated-list-print t)
                   (setq agent-review--agent-config agent-config)
                   (goto-char (point-min))))))
         (message "Detected language: %s" detected-language)
         (let ((issues (agent-review--parse-issues response)))
           (if issues
               (agent-review--display-issues issues agent-config
                                             review-buffer-name diagnostic-buffer-name)
             (message "No issues found in review")
             (when (buffer-live-p status-buffer)
               (with-current-buffer status-buffer
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
