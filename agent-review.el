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

(defcustom agent-review-save-directory
  (expand-file-name "agent-review-saves" user-emacs-directory)
  "Directory where saved reviews are stored."
  :type 'directory
  :group 'agent-review)

(defcustom agent-review-language-prompts-directory nil
  "Directory containing custom language prompt files.
When set, agent-review looks here first for language prompt files
\(e.g. \"python.md\", \"clojure.md\") before falling back to the
built-in prompts shipped with the package."
  :type '(choice (const :tag "Use built-in prompts" nil)
                 (directory :tag "Custom prompts directory"))
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

(defvar-local agent-review--pr-url nil
  "GitHub PR URL for the current review, when reviewing a PR.")

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

(defun agent-review--parse-pr-url (url)
  "Parse a GitHub PR URL into (OWNER/REPO . NUMBER).
URL should be like https://github.com/owner/repo/pull/123."
  (if (string-match "github\\.com/\\([^/]+/[^/]+\\)/pull/\\([0-9]+\\)" url)
      (cons (match-string 1 url)
            (match-string 2 url))
    (user-error "Invalid GitHub PR URL: %s" url)))

(defun agent-review--get-pr-diff (pr-url)
  "Fetch the diff for a GitHub PR at PR-URL using the gh CLI.
Returns a changes alist with a :pr-diff key."
  (unless (executable-find "gh")
    (user-error "gh CLI not found.  Install it from https://cli.github.com"))
  (let* ((parsed (agent-review--parse-pr-url pr-url))
         (repo (car parsed))
         (number (cdr parsed)))
    (with-temp-buffer
      (let ((exit-code (call-process "gh" nil t nil
                                     "pr" "diff" number
                                     "--repo" repo)))
        (if (zerop exit-code)
            (let ((diff (buffer-string)))
              (if (string-empty-p (string-trim diff))
                  (user-error "PR %s#%s has no diff" repo number)
                (list (cons :pr-diff diff))))
          (error "gh pr diff failed (exit %d): %s"
                 exit-code (string-trim (buffer-string))))))))

(defun agent-review--get-pr-metadata (pr-url)
  "Fetch metadata for a GitHub PR at PR-URL using the gh CLI.
Returns a parsed JSON alist with keys: title, body, author, labels,
baseRefName, headRefName, url, number."
  (unless (executable-find "gh")
    (user-error "gh CLI not found.  Install it from https://cli.github.com"))
  (let* ((parsed (agent-review--parse-pr-url pr-url))
         (repo (car parsed))
         (number (cdr parsed)))
    (with-temp-buffer
      (let ((exit-code (call-process "gh" nil t nil
                                     "pr" "view" number
                                     "--repo" repo
                                     "--json" "title,body,author,labels,baseRefName,headRefName,url,number")))
        (if (zerop exit-code)
            (json-read-from-string (buffer-string))
          (error "gh pr view failed (exit %d): %s"
                 exit-code (string-trim (buffer-string))))))))

(defun agent-review--get-commit-range-diff (commit-range)
  "Get diff for COMMIT-RANGE (e.g. \"abc123..def456\").
Returns a changes alist with a :commit-diff key."
  (agent-review--check-git-repo)
  (let ((diff (agent-review--get-git-diff (list commit-range))))
    (unless diff
      (user-error "No diff for commit range: %s" commit-range))
    (list (cons :commit-diff diff))))

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
    (when-let ((commit-diff (alist-get :commit-diff changes)))
      (setq files (append files (agent-review--changed-files commit-diff))))
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
    (when-let ((pr-diff (alist-get :pr-diff changes)))
      (push "=== Pull Request Diff ===\n\n" parts)
      (push pr-diff parts)
      (push "\n\n" parts))
    (when-let ((commit-diff (alist-get :commit-diff changes)))
      (push "=== Commit Range Diff ===\n\n" parts)
      (push commit-diff parts)
      (push "\n\n" parts))
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
Checks `agent-review-language-prompts-directory' first for a custom
prompt file, then falls back to the built-in languages/ directory.
Within each directory, falls back to \"other.md\" if no language-specific
file exists."
  (let* ((filename (format "%s.md" language))
         (custom-dir (and agent-review-language-prompts-directory
                         (expand-file-name agent-review-language-prompts-directory)))
         (custom-file (and custom-dir
                           (expand-file-name filename custom-dir)))
         (custom-fallback (and custom-dir
                               (expand-file-name "other.md" custom-dir)))
         (pkg-dir (file-name-directory (locate-library "agent-review")))
         (builtin-file (expand-file-name (concat "languages/" filename) pkg-dir))
         (builtin-fallback (expand-file-name "languages/other.md" pkg-dir))
         (file (cond
                ((and custom-file (file-exists-p custom-file)) custom-file)
                ((and custom-fallback (file-exists-p custom-fallback)) custom-fallback)
                ((file-exists-p builtin-file) builtin-file)
                (t builtin-fallback))))
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
   "lib/utils.el:15|warning|Missing docstring|Public function `parse-input` lacks a docstring.\\nAll public API functions should document their parameters and return values.\\n\\n**Fix Suggestion**: Add a docstring describing the expected input format and return type.\n"
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


(defun agent-review--request-prompt-async (prompt-text config on-complete)
  "Send PROMPT-TEXT to agent using CONFIG and call ON-COMPLETE when done.
ON-COMPLETE is called with (response-text error) where error is nil on success.
This is a single-turn prompt without language detection."
  (let* ((work-buffer (generate-new-buffer " *agent-review-prompt-work*"))
         (client nil)
         (session-id nil))
    (with-current-buffer work-buffer
      (setq agent-review--session-response-text "")
      (setq client (funcall (alist-get :client-maker config) work-buffer))
      (setq agent-review--session-client client)
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
      (acp-subscribe-to-errors
       :client client
       :buffer work-buffer
       :on-error
       (lambda (err)
         (agent-review--cleanup-session work-buffer)
         (kill-buffer work-buffer)
         (funcall on-complete nil (format "Agent error: %S" err))))
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
                  (acp-send-request
                   :client client
                   :sync nil
                   :request (acp-make-session-prompt-request
                             :session-id session-id
                             :prompt (vector (list (cons 'type "text")
                                                   (cons 'text prompt-text))))
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
                     (funcall on-complete nil (format "Prompt failed: %S" err)))))))
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

(defun agent-review-dismiss ()
  "Dismiss marked issues (or issue at point) as irrelevant.
Removes them from the review buffer."
  (interactive)
  (let ((issues (agent-review--get-marked-issues)))
    (unless issues
      (user-error "No issue at point"))
    (let ((count (length issues)))
      (dolist (issue issues)
        (setq agent-review--current-issues
              (delete issue agent-review--current-issues))
        (when agent-review--marked-issues
          (remhash issue agent-review--marked-issues)))
      (setq tabulated-list-entries
            (mapcar #'agent-review--format-entry agent-review--current-issues))
      (tabulated-list-print t)
      (message "Dismissed %d issue%s" count (if (= count 1) "" "s")))))

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

;;; GitHub Integration

(defun agent-review--format-issue-as-gh-body (issue)
  "Format ISSUE plist into a GitHub issue markdown body."
  (format "## %s\n\n**File:** `%s:%d`\n**Severity:** %s\n\n### Diagnostic\n\n%s\n\n---\n*Generated by agent-review.el*"
          (plist-get issue :short-description)
          (plist-get issue :file)
          (plist-get issue :line)
          (upcase (plist-get issue :severity))
          (plist-get issue :diagnostic)))

(defun agent-review--format-issues-as-gh-body (issues)
  "Format multiple ISSUES into a single GitHub issue markdown body."
  (let ((sections
         (cl-loop for issue in issues
                  for i from 1
                  collect (format "### %d. [%s] %s\n\n**File:** `%s:%d`\n\n%s"
                                  i
                                  (upcase (plist-get issue :severity))
                                  (plist-get issue :short-description)
                                  (plist-get issue :file)
                                  (plist-get issue :line)
                                  (plist-get issue :diagnostic)))))
    (concat (format "## Code review: %d issues\n\n" (length issues))
            (mapconcat #'identity sections "\n\n")
            "\n\n---\n*Generated by agent-review.el*")))

(defun agent-review--gh-create-issue (title body)
  "Create a GitHub issue with TITLE and BODY using gh CLI.
Returns the issue URL on success."
  (unless (executable-find "gh")
    (user-error "gh CLI not found.  Install it from https://cli.github.com"))
  (with-temp-buffer
    (let ((exit-code (call-process "gh" nil t nil
                                   "issue" "create"
                                   "--title" title
                                   "--body" body)))
      (if (zerop exit-code)
          (string-trim (buffer-string))
        (error "gh issue create failed (exit %d): %s"
               exit-code (string-trim (buffer-string)))))))

(defun agent-review-create-github-issue ()
  "Create a GitHub issue from marked review issues, or issue at point.
Uses the gh CLI to create the issue in the current repository."
  (interactive)
  (let ((issues (agent-review--get-marked-issues)))
    (unless issues
      (user-error "No issue at point"))
    (when (y-or-n-p (format "Create GitHub issue for %d review item%s? "
                            (length issues)
                            (if (= (length issues) 1) "" "s")))
      (let* ((single-p (= (length issues) 1))
             (title (if single-p
                        (let ((issue (car issues)))
                          (format "[%s] %s (%s:%d)"
                                  (upcase (plist-get issue :severity))
                                  (plist-get issue :short-description)
                                  (plist-get issue :file)
                                  (plist-get issue :line)))
                      (format "Code review: %d issues found" (length issues))))
             (body (if single-p
                       (agent-review--format-issue-as-gh-body (car issues))
                     (agent-review--format-issues-as-gh-body issues)))
             (url (agent-review--gh-create-issue title body)))
        (kill-new url)
        (message "Created GitHub issue: %s (URL copied)" url)))))

;;; GitHub PR Review

(defun agent-review--format-pr-review-comment-body (issue)
  "Format the body text for a PR review comment from ISSUE."
  (format "**[%s]** %s\n\n%s"
          (upcase (plist-get issue :severity))
          (plist-get issue :short-description)
          (plist-get issue :diagnostic)))

(defun agent-review--make-pr-review-comment (issue body)
  "Build a PR review comment alist from ISSUE plist and BODY text."
  (list (cons 'path (plist-get issue :file))
        (cons 'line (plist-get issue :line))
        (cons 'body body)))

(cl-defun agent-review--gh-submit-pr-review (&key pr-url event comments body)
  "Submit a GitHub PR review with line-level COMMENTS.
PR-URL is the GitHub pull request URL.
EVENT is the review event: \"COMMENT\", \"REQUEST_CHANGES\", or \"APPROVE\".
COMMENTS is a list of comment alists with path, line, and body keys.
BODY is the review body text.  When nil, a default is generated."
  (unless (executable-find "gh")
    (user-error "gh CLI not found.  Install it from https://cli.github.com"))
  (let* ((parsed (agent-review--parse-pr-url pr-url))
         (repo (car parsed))
         (number (cdr parsed))
         (review-body (or body
                          (format "Code review: %d issue%s found.\n\n---\n*Generated by agent-review.el*"
                                  (length comments)
                                  (if (= (length comments) 1) "" "s"))))
         (payload (json-encode
                   (if comments
                       `((event . ,event)
                         (body . ,review-body)
                         (comments . ,(vconcat comments)))
                     `((event . ,event)
                       (body . ,review-body)))))
         (temp-file (make-temp-file "agent-review-" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert payload))
          (with-temp-buffer
            (let ((exit-code (call-process "gh" nil t nil
                                           "api"
                                           "--method" "POST"
                                           "-H" "Accept: application/vnd.github+json"
                                           "-H" "X-GitHub-Api-Version: 2022-11-28"
                                           (format "/repos/%s/pulls/%s/reviews" repo number)
                                           "--input" temp-file)))
              (if (zerop exit-code)
                  (let* ((response (json-read-from-string (buffer-string)))
                         (html-url (alist-get 'html_url response)))
                    (or html-url
                        (format "https://github.com/%s/pull/%s" repo number)))
                (error "gh api failed (exit %d): %s"
                       exit-code (string-trim (buffer-string)))))))
      (delete-file temp-file))))

(defun agent-review--gh-get-pr-head-sha (repo number)
  "Get the HEAD commit SHA for PR NUMBER in REPO."
  (with-temp-buffer
    (let ((exit-code (call-process "gh" nil t nil
                                   "api"
                                   "-H" "Accept: application/vnd.github+json"
                                   (format "/repos/%s/pulls/%s" repo number)
                                   "--jq" ".head.sha")))
      (if (zerop exit-code)
          (string-trim (buffer-string))
        (error "Failed to get PR head SHA (exit %d): %s"
               exit-code (string-trim (buffer-string)))))))

(cl-defun agent-review--gh-submit-standalone-comments (&key pr-url comments)
  "Post each comment in COMMENTS as a standalone PR comment.
PR-URL is the GitHub pull request URL.
COMMENTS is a list of comment alists with path, line, and body keys.
Returns the PR URL."
  (unless (executable-find "gh")
    (user-error "gh CLI not found.  Install it from https://cli.github.com"))
  (let* ((parsed (agent-review--parse-pr-url pr-url))
         (repo (car parsed))
         (number (cdr parsed))
         (commit-id (agent-review--gh-get-pr-head-sha repo number))
         (posted 0))
    (dolist (comment comments)
      (let* ((payload (json-encode
                       `((body . ,(alist-get 'body comment))
                         (path . ,(alist-get 'path comment))
                         (line . ,(alist-get 'line comment))
                         (commit_id . ,commit-id))))
             (temp-file (make-temp-file "agent-review-" nil ".json")))
        (unwind-protect
            (progn
              (with-temp-file temp-file
                (insert payload))
              (with-temp-buffer
                (let ((exit-code (call-process "gh" nil t nil
                                               "api"
                                               "--method" "POST"
                                               "-H" "Accept: application/vnd.github+json"
                                               "-H" "X-GitHub-Api-Version: 2022-11-28"
                                               (format "/repos/%s/pulls/%s/comments" repo number)
                                               "--input" temp-file)))
                  (if (zerop exit-code)
                      (cl-incf posted)
                    (error "gh api failed posting comment on %s:%d (exit %d): %s"
                           (alist-get 'path comment)
                           (alist-get 'line comment)
                           exit-code (string-trim (buffer-string)))))))
          (delete-file temp-file))))
    (message "Posted %d standalone comment%s" posted (if (= posted 1) "" "s"))
    (format "https://github.com/%s/pull/%s" repo number)))

;; Comment edit buffer

(defvar-local agent-review--edit-issue nil
  "The issue plist being edited in this comment buffer.")

(defvar-local agent-review--edit-remaining nil
  "Remaining issues to edit after the current one.")

(defvar-local agent-review--edit-collected nil
  "Accumulated comment alists already confirmed by the user.")

(defvar-local agent-review--edit-pr-url nil
  "PR URL for the review being composed.")

(defvar-local agent-review--edit-event nil
  "Review event type (COMMENT, REQUEST_CHANGES, APPROVE).")

(defvar-local agent-review--edit-submit-mode nil
  "Submission mode: `review' for a PR review, `standalone' for individual comments.")

(defvar-local agent-review--edit-review-buffer nil
  "The agent-review buffer that initiated the edit flow.")

(defvar agent-review-edit-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-review-edit-comment-confirm)
    (define-key map (kbd "C-c C-k") #'agent-review-edit-comment-abort)
    map)
  "Keymap for `agent-review-edit-comment-mode'.")

(define-derived-mode agent-review-edit-comment-mode text-mode "Review Comment"
  "Mode for editing a PR review comment before submission.

\\<agent-review-edit-comment-mode-map>\
\\[agent-review-edit-comment-confirm] to confirm and advance to next issue.
\\[agent-review-edit-comment-abort] to abort the entire review submission.")

(defun agent-review--edit-comment-header (issue index total)
  "Return a read-only header string for ISSUE at INDEX of TOTAL."
  (propertize
   (format "# Editing comment %d/%d — %s:%d [%s]\n# C-c C-c to confirm, C-c C-k to abort\n# ── Everything below this line is the comment body ──\n"
           index total
           (plist-get issue :file)
           (plist-get issue :line)
           (upcase (plist-get issue :severity)))
   'face 'font-lock-comment-face
   'read-only t
   'front-sticky '(read-only)
   'rear-nonsticky '(read-only)))

(defun agent-review--edit-show-issue (issue remaining collected pr-url event submit-mode review-buffer index total)
  "Show edit buffer for ISSUE.
REMAINING is the list of issues still to edit.
COLLECTED is the list of comment alists already confirmed.
PR-URL, EVENT, SUBMIT-MODE, and REVIEW-BUFFER are forwarded for final submission.
SUBMIT-MODE is `review' or `standalone'.
INDEX and TOTAL are for the progress header."
  (let ((buffer (get-buffer-create "*Agent Review Comment*")))
    (with-current-buffer buffer
      (agent-review-edit-comment-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-review--edit-comment-header issue index total))
        (insert (agent-review--format-pr-review-comment-body issue)))
      (setq agent-review--edit-issue issue)
      (setq agent-review--edit-remaining remaining)
      (setq agent-review--edit-collected collected)
      (setq agent-review--edit-pr-url pr-url)
      (setq agent-review--edit-event event)
      (setq agent-review--edit-submit-mode submit-mode)
      (setq agent-review--edit-review-buffer review-buffer)
      (goto-char (point-min))
      ;; Move past the header to the editable body
      (forward-line 3)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

(defun agent-review--edit-extract-body ()
  "Extract the editable comment body from the current edit buffer.
Skips the read-only header lines."
  (save-excursion
    (goto-char (point-min))
    (forward-line 3)
    (string-trim (buffer-substring-no-properties (point) (point-max)))))

(defun agent-review-edit-comment-confirm ()
  "Confirm the current comment and advance to the next issue.
When all issue comments are done, shows the review body edit buffer.
When in the body edit buffer, submits the review."
  (interactive)
  (if (null agent-review--edit-issue)
      ;; Body edit buffer — submit
      (agent-review--edit-body-confirm)
    ;; Issue comment buffer — collect and advance
    (let* ((body (agent-review--edit-extract-body))
           (comment (agent-review--make-pr-review-comment
                     agent-review--edit-issue body))
           (collected (append agent-review--edit-collected (list comment)))
           (remaining agent-review--edit-remaining)
           (pr-url agent-review--edit-pr-url)
           (event agent-review--edit-event)
           (submit-mode agent-review--edit-submit-mode)
           (review-buffer agent-review--edit-review-buffer)
           (total (+ (length collected) (length remaining))))
      (if remaining
          ;; Show next issue
          (agent-review--edit-show-issue
           (car remaining) (cdr remaining) collected
           pr-url event submit-mode review-buffer
           (1+ (length collected)) total)
        ;; All issues reviewed — show body edit buffer
        (agent-review--edit-show-body collected pr-url event submit-mode review-buffer)))))

(defvar-local agent-review--edit-body-collected nil
  "Collected comments for the body edit buffer.")

(defvar-local agent-review--edit-body-pr-url nil
  "PR URL for the body edit buffer.")

(defvar-local agent-review--edit-body-event nil
  "Review event type for the body edit buffer.")

(defvar-local agent-review--edit-body-submit-mode nil
  "Submission mode for the body edit buffer.")

(defvar-local agent-review--edit-body-review-buffer nil
  "Review buffer for the body edit buffer.")

(defun agent-review--edit-body-default (n-comments)
  "Return default review body text for N-COMMENTS inline comments."
  (if (zerop n-comments)
      "LGTM\n\n---\n*Generated by agent-review.el*"
    (format "Code review: %d issue%s found.\n\n---\n*Generated by agent-review.el*"
            n-comments
            (if (= n-comments 1) "" "s"))))

(defun agent-review--edit-body-header ()
  "Return a read-only header string for the body edit buffer."
  (propertize
   "# Review body message\n# C-c C-c to submit, C-c C-k to abort\n# ── Everything below this line is the review body ──\n"
   'face 'font-lock-comment-face
   'read-only t
   'front-sticky '(read-only)
   'rear-nonsticky '(read-only)))

(defun agent-review--edit-show-body (collected pr-url event submit-mode review-buffer)
  "Show edit buffer for the review body message.
COLLECTED is the list of comment alists.
PR-URL, EVENT, SUBMIT-MODE, and REVIEW-BUFFER are for final submission."
  (let ((buffer (get-buffer-create "*Agent Review Comment*")))
    (with-current-buffer buffer
      (agent-review-edit-comment-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-review--edit-body-header))
        (insert (agent-review--edit-body-default (length collected))))
      (setq agent-review--edit-body-collected collected)
      (setq agent-review--edit-body-pr-url pr-url)
      (setq agent-review--edit-body-event event)
      (setq agent-review--edit-body-submit-mode submit-mode)
      (setq agent-review--edit-body-review-buffer review-buffer)
      ;; Mark this as a body buffer so confirm knows what to do
      (setq agent-review--edit-issue nil)
      (goto-char (point-min))
      (forward-line 3)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

(defun agent-review--edit-body-confirm ()
  "Confirm the review body and submit the review."
  (let* ((body (agent-review--edit-extract-body))
         (collected agent-review--edit-body-collected)
         (pr-url agent-review--edit-body-pr-url)
         (event agent-review--edit-body-event)
         (submit-mode agent-review--edit-body-submit-mode))
    (quit-window t)
    (pcase submit-mode
      ('review
       (when (y-or-n-p (format "Submit %s review%s? "
                               event
                               (if collected
                                   (format " with %d comment%s"
                                           (length collected)
                                           (if (= (length collected) 1) "" "s"))
                                 "")))
         (let ((url (agent-review--gh-submit-pr-review
                     :pr-url pr-url
                     :event event
                     :comments collected
                     :body body)))
           (when (string= event "APPROVE")
             (agent-review--blind-approve-record pr-url))
           (kill-new url)
           (message "PR review submitted: %s (URL copied)" url))))
      ('standalone
       (when (y-or-n-p (format "Post %d standalone comment%s? "
                               (length collected)
                               (if (= (length collected) 1) "" "s")))
         (let ((url (agent-review--gh-submit-standalone-comments
                     :pr-url pr-url
                     :comments collected)))
           (kill-new url)
           (message "Standalone comments posted: %s (URL copied)" url)))))))

(defun agent-review-edit-comment-abort ()
  "Abort the review submission, discarding all edits."
  (interactive)
  (when (y-or-n-p "Abort review submission? ")
    (quit-window t)
    (message "PR review submission aborted")))

(defun agent-review-submit-pr-review ()
  "Submit marked issues (or all issues) to a GitHub PR.
Prompts for submission mode: review (bundled with event type) or
standalone (individual comments).  Opens an edit buffer for each
comment before submission, then shows a body edit buffer as the
final step.  When no issues are selected, goes directly to the
body edit buffer.
Uses the gh CLI to post comments on the pull request."
  (interactive)
  (unless agent-review--pr-url
    (user-error "Not a PR review.  Use `agent-review-pr' to review a pull request first"))
  (let* ((issues (agent-review--get-marked-issues))
         (mode-choice (completing-read "Submit as: "
                                       '("Review" "Standalone comments")
                                       nil t nil nil "Review"))
         (submit-mode (if (string= mode-choice "Review") 'review 'standalone))
         (event (when (eq submit-mode 'review)
                  (completing-read "Review event: "
                                   '("COMMENT" "REQUEST_CHANGES" "APPROVE")
                                   nil t nil nil "COMMENT"))))
    (if issues
        (agent-review--edit-show-issue
         (car issues) (cdr issues) nil
         agent-review--pr-url event submit-mode (current-buffer)
         1 (length issues))
      ;; No issues — go directly to body edit buffer
      (agent-review--edit-show-body nil agent-review--pr-url event submit-mode (current-buffer)))))

;;; Save / Load Reviews

(defun agent-review--save-file-path (project-name)
  "Generate a save file path for PROJECT-NAME with a timestamp."
  (let ((dir agent-review-save-directory)
        (safe-name (replace-regexp-in-string "[^a-zA-Z0-9_-]" "_" project-name))
        (timestamp (format-time-string "%Y%m%dT%H%M%S")))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (expand-file-name (format "%s-%s.eld" safe-name timestamp) dir)))

(defun agent-review-save ()
  "Save the current review to disk for later loading."
  (interactive)
  (unless agent-review--current-issues
    (user-error "No issues to save"))
  (let* ((project-name (agent-review--project-name))
         (file (agent-review--save-file-path project-name))
         (data (list :version 1
                     :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S")
                     :project-directory default-directory
                     :project-name project-name
                     :agent-name (or (alist-get :mode-line-name agent-review--agent-config)
                                     "unknown")
                     :issues agent-review--current-issues)))
    (with-temp-file file
      (let ((print-level nil)
            (print-length nil))
        (prin1 data (current-buffer))))
    (message "Review saved to %s" (abbreviate-file-name file))))

(defun agent-review--list-saved-reviews ()
  "Return alist of (display-label . file-path) for saved reviews."
  (let ((dir agent-review-save-directory))
    (unless (file-directory-p dir)
      (user-error "No saved reviews (directory %s does not exist)" dir))
    (let ((files (directory-files dir t "\\.eld\\'" t)))
      (unless files
        (user-error "No saved reviews found in %s" dir))
      (mapcar
       (lambda (file)
         (condition-case nil
             (let* ((data (with-temp-buffer
                            (insert-file-contents file)
                            (read (current-buffer))))
                    (project (plist-get data :project-name))
                    (agent (plist-get data :agent-name))
                    (ts (plist-get data :timestamp))
                    (n-issues (length (plist-get data :issues)))
                    (label (format "%s  %s  %d issues  [%s]"
                                   project ts n-issues agent)))
               (cons label file))
           (error (cons (format "(unreadable) %s" (file-name-nondirectory file))
                        file))))
       files))))

(defun agent-review-load ()
  "Load a previously saved review from disk."
  (interactive)
  (let* ((entries (agent-review--list-saved-reviews))
         (choice (completing-read "Load review: " entries nil t))
         (file (cdr (assoc choice entries)))
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (read (current-buffer))))
         (project (plist-get data :project-name))
         (issues (plist-get data :issues))
         (project-dir (plist-get data :project-directory))
         (review-buf (format "*Agent Review @ %s*" project))
         (diag-buf (format "*Agent Review Diagnostic @ %s*" project)))
    (unless issues
      (user-error "Saved review contains no issues"))
    (let ((default-directory (if (file-directory-p project-dir)
                                 project-dir
                               default-directory)))
      (agent-review--display-issues issues nil review-buf diag-buf))))

(defun agent-review-delete-saved ()
  "Delete a saved review from disk."
  (interactive)
  (let* ((entries (agent-review--list-saved-reviews))
         (choice (completing-read "Delete saved review: " entries nil t))
         (file (cdr (assoc choice entries))))
    (when (y-or-n-p (format "Delete %s? " (file-name-nondirectory file)))
      (delete-file file)
      (message "Deleted %s" (file-name-nondirectory file)))))

;;; Blind Approve

(defun agent-review--blind-approve-file ()
  "Return the path to the blind-approve persistence file."
  (let ((dir agent-review-save-directory))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (expand-file-name "blind-approve-list.eld" dir)))

(defun agent-review--blind-approve-load ()
  "Load and return the list of previously approved PR URLs."
  (let ((file (agent-review--blind-approve-file)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))
      nil)))

(defun agent-review--blind-approve-save (urls)
  "Save URLS as the blind-approve list to disk."
  (let ((file (agent-review--blind-approve-file)))
    (with-temp-file file
      (let ((print-level nil)
            (print-length nil))
        (prin1 urls (current-buffer))))))

(defun agent-review--blind-approve-record (pr-url)
  "Add PR-URL to the blind-approve list if not already present."
  (let ((urls (agent-review--blind-approve-load)))
    (unless (member pr-url urls)
      (agent-review--blind-approve-save (append urls (list pr-url))))))

(defun agent-review--pr-title-for-url (pr-url)
  "Fetch the PR title for PR-URL using the gh CLI.
Returns the title string, or the URL itself on failure."
  (condition-case nil
      (let* ((parsed (agent-review--parse-pr-url pr-url))
             (repo (car parsed))
             (number (cdr parsed)))
        (with-temp-buffer
          (let ((exit-code (call-process "gh" nil t nil
                                         "pr" "view" number
                                         "--repo" repo
                                         "--json" "title"
                                         "--jq" ".title")))
            (if (zerop exit-code)
                (string-trim (buffer-string))
              pr-url))))
    (error pr-url)))

(defun agent-review-re-approve ()
  "Re-approve a previously reviewed PR.
Prompts to select from PRs that were previously approved via
agent-review, then sends an APPROVE review to GitHub."
  (interactive)
  (let ((urls (agent-review--blind-approve-load)))
    (unless urls
      (user-error "No previously approved PRs recorded"))
    (message "Fetching PR titles...")
    (let* ((entries (mapcar (lambda (url)
                              (let ((title (agent-review--pr-title-for-url url)))
                                (cons (format "%s  (%s)" title
                                              (replace-regexp-in-string
                                               "^https://github\\.com/" "" url))
                                url)))
                            urls))
           (choice (completing-read "Re-approve PR: " entries nil t))
           (pr-url (cdr (assoc choice entries))))
      (agent-review--parse-pr-url pr-url)
      (let ((url (agent-review--gh-submit-pr-review
                  :pr-url pr-url
                  :event "APPROVE"
                  :body "LGTM\n\n---\n*Generated by agent-review.el*")))
        (kill-new url)
        (message "PR approved: %s (URL copied)" url)))))

(defun agent-review-blind-approve (pr-url)
  "Approve a PR directly given its URL, no questions asked.
PR-URL should be a GitHub PR URL like
https://github.com/owner/repo/pull/123."
  (interactive "sApprove PR URL: ")
  (agent-review--parse-pr-url pr-url) ; validate
  (let ((url (agent-review--gh-submit-pr-review
              :pr-url pr-url
              :event "APPROVE"
              :body "LGTM\n\n---\n*Generated by agent-review.el*")))
    (agent-review--blind-approve-record pr-url)
    (kill-new url)
    (message "PR approved: %s (URL copied)" url)))

(defun agent-review--gh-pr-state (pr-url)
  "Return the state of the PR at PR-URL (\"open\", \"closed\", or \"merged\").
Uses the gh CLI."
  (let* ((parsed (agent-review--parse-pr-url pr-url))
         (repo (car parsed))
         (number (cdr parsed)))
    (with-temp-buffer
      (let ((exit-code (call-process "gh" nil t nil
                                     "api"
                                     "-H" "Accept: application/vnd.github+json"
                                     (format "/repos/%s/pulls/%s" repo number)
                                     "--jq" ".state")))
        (if (zerop exit-code)
            (string-trim (buffer-string))
          "unknown")))))

(defun agent-review-clean-reviews ()
  "Remove merged or closed PRs from the blind-approve list."
  (interactive)
  (let* ((urls (agent-review--blind-approve-load))
         (total (length urls))
         (remaining nil)
         (removed 0))
    (unless urls
      (user-error "No previously approved PRs recorded"))
    (message "Checking %d PR%s..." total (if (= total 1) "" "s"))
    (dolist (url urls)
      (let ((state (agent-review--gh-pr-state url)))
        (if (member state '("closed" "merged"))
            (cl-incf removed)
          (push url remaining))))
    (agent-review--blind-approve-save (nreverse remaining))
    (message "Removed %d PR%s (%d remaining)"
             removed (if (= removed 1) "" "s") (length remaining))))

;;; PR Overview Buffer

(defvar-local agent-review-pr-overview--pr-url nil
  "GitHub PR URL for this overview buffer.")

(defvar-local agent-review-pr-overview--metadata nil
  "Parsed PR metadata alist for this overview buffer.")

(defvar-local agent-review-pr-overview--diff nil
  "Cached PR diff (changes alist) for code review.")

(defvar-local agent-review-pr-overview--explanation nil
  "Agent explanation text, nil until requested.")

(defvar-local agent-review-pr-overview--agent-config nil
  "Agent configuration for this overview buffer.")

(defvar-local agent-review-pr-overview--explaining nil
  "Non-nil when an explain request is in progress.")

(defun agent-review-pr-overview--render ()
  "Render the PR overview into the current buffer."
  (let ((inhibit-read-only t)
        (metadata agent-review-pr-overview--metadata)
        (explanation agent-review-pr-overview--explanation)
        (explaining agent-review-pr-overview--explaining))
    (erase-buffer)
    ;; Keybinding hints
    (let ((hint (lambda (key desc)
                  (concat (propertize key 'face 'help-key-binding)
                          " " (propertize desc 'face 'shadow) "  "))))
      (insert (funcall hint "E" "explain PR")
              (funcall hint "I" "investigate")
              (funcall hint "R" "submit review")
              (funcall hint "c" "code review")
              (funcall hint "q" "quit")
              "\n\n"))
    ;; Title
    (let ((title (alist-get 'title metadata)))
      (insert (propertize title 'face '(:weight bold :height 1.3)) "\n\n"))
    ;; Author and branch info
    (let* ((author (alist-get 'login (alist-get 'author metadata)))
           (base (alist-get 'baseRefName metadata))
           (head (alist-get 'headRefName metadata)))
      (insert (propertize "Author: " 'face 'bold) (or author "unknown") "  "
              (propertize "Branch: " 'face 'bold) (or head "?")
              " → " (or base "?") "\n"))
    ;; Labels
    (let ((labels (alist-get 'labels metadata)))
      (when (and labels (> (length labels) 0))
        (insert (propertize "Labels: " 'face 'bold)
                (mapconcat (lambda (l) (alist-get 'name l))
                           (append labels nil)
                           ", ")
                "\n")))
    ;; Separator
    (insert "\n" (propertize (make-string 72 ?─) 'face 'shadow) "\n\n")
    ;; PR body
    (let ((body (alist-get 'body metadata))
          (body-start (point)))
      (if (and body (not (string-empty-p (string-trim body))))
          (progn
            (insert body)
            (agent-review-diagnostic--fontify-markdown body-start (point)))
        (insert (propertize "(no description)" 'face 'shadow))))
    ;; Explanation section
    (when (or explanation explaining)
      (insert "\n\n" (propertize (make-string 72 ?═) 'face 'shadow) "\n")
      (insert (propertize "PR Explanation" 'face '(:weight bold :height 1.1)) "\n\n")
      (if explaining
          (insert (propertize "Explaining PR..." 'face 'shadow))
        (let ((expl-start (point)))
          (insert explanation)
          (agent-review-diagnostic--fontify-markdown expl-start (point)))))
    (goto-char (point-min))))

(defun agent-review-pr-overview-explain ()
  "Ask an agent to explain the PR: What, Why, Pros, Cons."
  (interactive)
  (when agent-review-pr-overview--explaining
    (user-error "Explanation already in progress"))
  (when agent-review-pr-overview--explanation
    (unless (y-or-n-p "Re-explain PR? ")
      (user-error "Cancelled")))
  (let* ((metadata agent-review-pr-overview--metadata)
         (config agent-review-pr-overview--agent-config)
         (diff agent-review-pr-overview--diff)
         (title (alist-get 'title metadata))
         (body (or (alist-get 'body metadata) ""))
         (diff-text (or (alist-get :pr-diff diff) ""))
         (overview-buffer (current-buffer))
         (prompt (format "You are reviewing a Pull Request.

## PR Title
%s

## PR Description
%s

## PR Diff
%s

---

Explain this Pull Request concisely. Structure your response as:

**What has been implemented:** Describe the changes made.

**Why:** Explain the motivation and context.

**Pros:** List the benefits of this approach.

**Cons:** List any downsides, risks, or concerns."
                         title body diff-text)))
    (setq agent-review-pr-overview--explaining t)
    (setq agent-review-pr-overview--explanation nil)
    (agent-review-pr-overview--render)
    (message "Requesting PR explanation from %s..."
             (or (alist-get :mode-line-name config) "agent"))
    (agent-review--request-prompt-async
     prompt config
     (lambda (response error-msg)
       (when (buffer-live-p overview-buffer)
         (with-current-buffer overview-buffer
           (setq agent-review-pr-overview--explaining nil)
           (if error-msg
               (progn
                 (message "Explanation failed: %s" error-msg)
                 (agent-review-pr-overview--render))
             (setq agent-review-pr-overview--explanation (concat response "\n\n"))
             (agent-review-pr-overview--render)
             (message "PR explanation complete"))))))))

(defun agent-review-pr-overview-investigate ()
  "Ask a question about the PR in agent-shell.
When a region is active, use the selected text as context instead
of the full PR description and explanation."
  (interactive)
  (let* ((selection (when (use-region-p)
                      (buffer-substring-no-properties (region-beginning) (region-end))))
         (message-text (read-string "Investigate: "))
         (context (if selection
                      selection
                    (let* ((metadata agent-review-pr-overview--metadata)
                           (title (alist-get 'title metadata))
                           (body (or (alist-get 'body metadata) ""))
                           (explanation (or agent-review-pr-overview--explanation "")))
                      (concat "PR: " title "\n\n"
                              (unless (string-empty-p body)
                                (concat "Description:\n" body "\n\n"))
                              (unless (string-empty-p explanation)
                                (concat "Agent Explanation:\n" explanation "\n"))))))
         (full-text (concat message-text
                            "\n\nContext from PR overview:\n\n"
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
         (message "Cancelled"))))))

(defun agent-review-pr-overview-submit-review ()
  "Submit a review for this PR (no line comments, body only)."
  (interactive)
  (let* ((pr-url agent-review-pr-overview--pr-url)
         (event (completing-read "Review event: "
                                 '("COMMENT" "REQUEST_CHANGES" "APPROVE")
                                 nil t nil nil "COMMENT")))
    (agent-review--edit-show-body nil pr-url event 'review (current-buffer))))

(defun agent-review-pr-overview-code-review ()
  "Start a full code review of this PR."
  (interactive)
  (let* ((changes agent-review-pr-overview--diff)
         (config agent-review-pr-overview--agent-config)
         (pr-url agent-review-pr-overview--pr-url)
         (review-buffer-name (agent-review--buffer-name))
         (diagnostic-buffer-name (agent-review--diagnostic-buffer-name))
         (status-buffer
          (agent-review--show-status-buffer
           review-buffer-name
           (or (alist-get :mode-line-name config)
               (alist-get :buffer-name config)
               "agent"))))
    (agent-review--start-progress status-buffer)
    (message "Requesting code review from %s..."
             (or (alist-get :mode-line-name config) "agent"))
    (agent-review--request-review-async
     changes config status-buffer
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
                   (setq agent-review--agent-config config)
                   (goto-char (point-min))))))
         (message "Detected language: %s" detected-language)
         (let ((issues (agent-review--parse-issues response)))
           (if issues
               (progn
                 (agent-review--display-issues issues config
                                               review-buffer-name diagnostic-buffer-name)
                 (with-current-buffer (get-buffer review-buffer-name)
                   (setq agent-review--pr-url pr-url)))
             (message "No issues found in review")
             (when (buffer-live-p status-buffer)
               (with-current-buffer status-buffer
                 (let ((inhibit-read-only t))
                   (setq tabulated-list-format [("Status" 0 nil)])
                   (tabulated-list-init-header)
                   (setq tabulated-list-entries
                         (list (list 'status (vector "Review complete: No issues found"))))
                   (tabulated-list-print t)
                   (setq agent-review--agent-config config)
                   (goto-char (point-min))))))))))))

(defvar-keymap agent-review-pr-overview-mode-map
  :doc "Keymap for `agent-review-pr-overview-mode'."
  :parent special-mode-map
  "E" #'agent-review-pr-overview-explain
  "I" #'agent-review-pr-overview-investigate
  "R" #'agent-review-pr-overview-submit-review
  "c" #'agent-review-pr-overview-code-review
  "q" #'quit-window)

(define-derived-mode agent-review-pr-overview-mode special-mode "AR-Overview"
  "Major mode for displaying a PR overview before code review.

\\{agent-review-pr-overview-mode-map}"
  (setq truncate-lines nil))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-review-pr-overview-mode 'normal)
  (evil-define-key* 'normal agent-review-pr-overview-mode-map
    "E" #'agent-review-pr-overview-explain
    "I" #'agent-review-pr-overview-investigate
    "R" #'agent-review-pr-overview-submit-review
    "c" #'agent-review-pr-overview-code-review
    "q" #'quit-window)
  (evil-define-key* 'visual agent-review-pr-overview-mode-map
    "I" #'agent-review-pr-overview-investigate))


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
    ;; Keybinding hints (single line header)
    (let ((hint (lambda (key desc)
                  (concat (propertize key 'face 'help-key-binding)
                          " " (propertize desc 'face 'shadow) "  "))))
      (insert (funcall hint "RET" "jump to file")
              (funcall hint "W" "copy")
              (funcall hint "q" "quit")
              (funcall hint "I" "investigate")
              (funcall hint "S" "fix in agent-shell")
              (funcall hint "n/p" "navigate")
              "\n"))
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
    ;; Diagnostic body (markdown fontified)
    (let ((diag-start (point)))
      (insert diagnostic)
      (agent-review-diagnostic--fontify-markdown diag-start (point)))
    ;; Hard-wrap entire buffer at column 80
    (agent-review-diagnostic--hard-wrap (point-min) (point-max) 80)
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
  "R" #'agent-review-submit-pr-review
  "n" #'agent-review-diagnostic-next
  "p" #'agent-review-diagnostic-prev
  "q" #'quit-window)

(define-derived-mode agent-review-diagnostic-mode special-mode "AR-Diagnostic"
  "Major mode for displaying a full diagnostic for a review issue.

\\{agent-review-diagnostic-mode-map}"
  (setq truncate-lines t))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-review-diagnostic-mode 'normal)
  (evil-define-key* 'normal agent-review-diagnostic-mode-map
    (kbd "RET") #'agent-review-diagnostic-jump-to-issue
    "o"  #'agent-review-diagnostic-jump-to-issue
    "I"  #'agent-review-diagnostic-investigate
    "S"  #'agent-review-diagnostic-send-to-agent-shell
    "W"  #'agent-review-diagnostic-copy-issue
    "R"  #'agent-review-submit-pr-review
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
  "l" #'agent-review-list-reviews
  "P" #'agent-review-pr
  "I" #'agent-review-create-github-issue
  "d" #'agent-review-dismiss
  "s" #'agent-review-save
  "C" #'agent-review-commits
  "R" #'agent-review-submit-pr-review)

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
  (evil-define-key* 'normal agent-review-mode-map
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
    "l"  #'agent-review-list-reviews
    "P"  #'agent-review-pr
    "I"  #'agent-review-create-github-issue
    "d"  #'agent-review-dismiss
    "s"  #'agent-review-save
    "C"  #'agent-review-commits
    "R"  #'agent-review-submit-pr-review))

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
  (evil-define-key* 'normal agent-review-list-mode-map
    (kbd "RET") #'agent-review-list-reviews-jump
    "q" #'quit-window))

;;;###autoload
(defun agent-review-list-reviews ()
  "List all Agent Review buffers and their statuses.
Displays in a side window for easy navigation."
  (interactive)
  (let ((buffer (get-buffer "*Agent Reviews*")))
    ;; If buffer is visible, hide it (toggle off)
    (if (and buffer (get-buffer-window buffer))
        (delete-window (get-buffer-window buffer))
      ;; Otherwise, show it (toggle on)
      (let ((reviews (agent-review--collect-review-buffers)))
        (if (null reviews)
            (message "No Agent Review buffers open")
          (setq buffer (get-buffer-create "*Agent Reviews*"))
          (with-current-buffer buffer
            (agent-review-list-mode)
            (agent-review-list-reviews-revert)
            (tabulated-list-print t)
            (goto-char (point-min)))
          (select-window
           (display-buffer-in-side-window buffer '((side . bottom)
                                                   (window-height . 0.3)))))))))

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

;;;###autoload
(defun agent-review-pr (pr-url &optional config)
  "Open a PR overview for the GitHub Pull Request at PR-URL.
Fetches PR metadata and diff, displays an overview buffer with
commands to explain, investigate, submit review, or start code review.
With optional CONFIG, use that agent configuration."
  (interactive "sGitHub PR URL: ")
  (unless (condition-case nil
              (agent-shell-project-buffers)
            (error nil))
    (user-error "No agent-shell session for this project.  Start one first with M-x agent-shell"))
  (let* ((agent-config (or config
                           (agent-shell-select-config
                            :prompt "Select agent for review: ")))
         (buffer-name (format "*AR Overview @ %s*" (agent-review--project-name))))
    (message "Fetching PR metadata...")
    (let ((metadata (agent-review--get-pr-metadata pr-url))
          (changes (progn
                     (message "Fetching PR diff...")
                     (agent-review--get-pr-diff pr-url))))
      (let ((buffer (get-buffer-create buffer-name)))
        (with-current-buffer buffer
          (agent-review-pr-overview-mode)
          (setq agent-review-pr-overview--pr-url pr-url)
          (setq agent-review-pr-overview--metadata metadata)
          (setq agent-review-pr-overview--diff changes)
          (setq agent-review-pr-overview--agent-config agent-config)
          (setq agent-review-pr-overview--explanation nil)
          (setq agent-review-pr-overview--explaining nil)
          (agent-review-pr-overview--render))
        (pop-to-buffer buffer)
        (message "PR overview loaded")))))
;;; Magit Integration

(declare-function magit-region-values "magit-section" (&rest types))

(defun agent-review--magit-commit-range ()
  "Derive a commit range from the magit log buffer selection.
Returns a string like \"older..newer\" or nil if not in a magit log buffer
or no region is active."
  (when (and (derived-mode-p 'magit-log-mode)
             (use-region-p)
             (fboundp 'magit-region-values))
    (let ((commits (magit-region-values 'commit)))
      (when (>= (length commits) 2)
        ;; magit lists newest first, so last element is the oldest
        (format "%s..%s" (car (last commits)) (car commits))))))

(defun agent-review-commits (&optional commit-range config)
  "Review changes in COMMIT-RANGE using an AI agent.
COMMIT-RANGE is a git revision range like \"abc123..def456\".
When called from a magit log buffer with a region, the range is
derived automatically from the selected commits.
With optional CONFIG, use that agent configuration."
  (interactive
   (list (or (agent-review--magit-commit-range)
             (read-string "Commit range (e.g. HEAD~3..HEAD): "))))
  (when (string-empty-p commit-range)
    (user-error "No commit range specified"))
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
                    (message "Fetching diff for %s..." commit-range)
                    (agent-review--get-commit-range-diff commit-range)))
         (status-buffer
          (agent-review--show-status-buffer
           review-buffer-name
           (or (alist-get :mode-line-name agent-config)
               (alist-get :buffer-name agent-config)
               "agent"))))

    ;; Start progress feedback
    (agent-review--start-progress status-buffer)

    ;; Request review asynchronously
    (message "Requesting commit range review from %s..."
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
