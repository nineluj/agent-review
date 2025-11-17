# Development Guide for agent-review.el

This document provides essential information for working with the agent-review codebase.

## Architecture Overview

agent-review.el is built on two key libraries:

1. **acp.el** - ACP (Agent Client Protocol) implementation
2. **agent-shell** - Multi-agent interface using acp.el

## Dependencies

### acp.el

Located at: `~/.config/emacs/.local/straight/repos/acp.el/`

**Purpose:** Low-level ACP protocol implementation

**Key Concepts:**

- **Client:** Created with `acp-make-client`, manages connection to an ACP agent
- **Requests:** Synchronous or async RPC calls to agent (e.g., initialize, create session, send prompt)
- **Notifications:** One-way messages from agent to client (e.g., status updates, streaming responses)
- **Responses:** Replies to client requests

**Common Functions:**

```elisp
;; Create a client
(acp-make-client :command "claude"
                 :command-params '("acp")
                 :environment-variables '("API_KEY=...")
                 :context-buffer (current-buffer))

;; Subscribe to notifications (for streaming agent output)
(acp-subscribe-to-notifications
 :client client
 :buffer (current-buffer)
 :on-notification (lambda (notification) ...))

;; Subscribe to errors
(acp-subscribe-to-errors
 :client client
 :buffer (current-buffer)
 :on-error (lambda (error) ...))

;; Send requests
(acp-send-request
 :client client
 :sync t  ; or nil for async
 :request (acp-make-initialize-request ...)
 :on-success (lambda (result) ...)
 :on-failure (lambda (error) ...))

;; Cleanup
(acp-shutdown :client client)
```

**Important Request Builders:**

- `acp-make-initialize-request` - Handshake with agent
  - `:protocol-version` must be a NUMBER (e.g., `1`, not `"1.0"`)
  - `:read-text-file-capability` and `:write-text-file-capability` are booleans

- `acp-make-session-new-request` - Create a session
  - `:cwd` is current working directory (string)
  - `:mcp-servers` is a vector (use `[]` for empty)

- `acp-make-session-prompt-request` - Send prompt to agent
  - `:session-id` from session creation response
  - `:prompt` is a VECTOR of content block objects
  - Content blocks have structure: `((type . "text") (text . "prompt text"))`

**Critical Details:**

1. Protocol version MUST be a number: `1` not `"0.1.0"`
2. Prompt parameter is a vector of alists, NOT a string or list
3. Use `(vector (list (cons 'type "text") (cons 'text "...")))` to build prompts
4. Agent responses stream via notifications, not request responses
5. Always cleanup with `acp-shutdown` when done

### agent-shell

Located at: `~/.config/emacs/.local/straight/repos/agent-shell/`

**Purpose:** High-level multi-agent interface with configuration system

**Key Concepts:**

- **Agent Config:** Alist containing agent metadata and client factory
- **Client Maker:** Function that creates an acp.el client for a specific agent

**Agent Configuration Structure:**

```elisp
(agent-shell-make-agent-config
 :mode-line-name "Claude Code"       ; Display name
 :buffer-name "Claude Code"          ; Buffer name
 :shell-prompt "Claude Code> "       ; Prompt string
 :shell-prompt-regexp "Claude Code> " ; Prompt regex
 :icon-name "anthropic.png"          ; Icon file
 :welcome-function #'some-function   ; Welcome message function
 :client-maker (lambda (buffer) ...) ; Function that creates acp client
 :install-instructions "...")        ; Help text if not installed
```

**Using Agent Configs:**

```elisp
;; Get all available agents
agent-shell-agent-configs

;; Let user select an agent
(agent-shell-select-config :prompt "Select agent: ")

;; Use the client-maker from a config
(let ((client (funcall (alist-get :client-maker config)
                       (current-buffer))))
  ;; client is now an acp.el client
  ...)
```

**Pre-made Configs:**

- `(agent-shell-anthropic-make-claude-code-config)` - Claude Code
- `(agent-shell-cursor-make-agent-config)` - Cursor
- `(agent-shell-google-make-gemini-config)` - Gemini CLI
- `(agent-shell-goose-make-agent-config)` - Goose
- `(agent-shell-openai-make-codex-config)` - Codex
- `(agent-shell-opencode-make-agent-config)` - OpenCode
- `(agent-shell-qwen-make-agent-config)` - Qwen

## agent-review.el Workflow

1. **Collect git changes** (`agent-review--get-git-changes`)
   - Run `git diff --cached` for staged
   - Run `git diff` for unstaged
   - Return alist: `((:staged . "...") (:unstaged . "..."))`

2. **Request review** (`agent-review--request-review`)
   - Create acp client using config's `:client-maker`
   - Subscribe to notifications to capture agent output
   - Send initialize request (protocol version 1)
   - Create session
   - Send prompt request with review instructions
   - Wait for completion
   - Cleanup session and client

3. **Parse response** (`agent-review--parse-issues`)
   - Extract lines matching: `FILE:LINE|SEVERITY|DESCRIPTION`
   - Build issue plists: `(:file "..." :line N :severity "..." :description "...")`
   - Sort by file, then severity (error > warning > suggestion)

4. **Display** (`agent-review--display-issues`)
   - Use `tabulated-list-mode`
   - Color-code severity levels
   - Allow navigation with RET

## Common Pitfalls

1. **Protocol version type mismatch**
   - WRONG: `:protocol-version "0.1.0"`
   - RIGHT: `:protocol-version 1`

2. **Prompt format**
   - WRONG: `:prompt "text"` or `:prompt '("text")`
   - RIGHT: `:prompt (vector (list (cons 'type "text") (cons 'text "...")))`

3. **Backtick in vector literals**
   - WRONG: `(vector \`((type . "text") (text . ,value)))`
   - RIGHT: `(vector (list (cons 'type "text") (cons 'text value)))`

4. **Not waiting for async responses**
   - Agent output streams via notifications
   - Must use `accept-process-output` or similar to wait
   - Check completion flags, don't assume immediate response

5. **Forgetting cleanup**
   - Always call `acp-shutdown :client client`
   - Use `unwind-protect` to ensure cleanup happens

## Testing

To test changes:

1. Load the file: `M-x load-file RET agent-review.el RET`
2. Navigate to a git repo with changes
3. Run: `M-x agent-review`
4. Select an agent
5. Check the `*Agent Review*` buffer for results

## Debugging

Enable ACP logging:

```elisp
(setq acp-logging-enabled t)
```

Then check buffers:
- `*acp-(command)-N log*` - Request/response logs
- `*acp-(command)-N traffic*` - Protocol traffic

## Code Style

- Use `cl-defun` for functions with keyword arguments
- Follow existing naming conventions:
  - Public API: `agent-review-*`
  - Private functions: `agent-review--*`
- Document all functions with docstrings
- Use `let*` when bindings depend on previous bindings
- Prefer `when-let` and `if-let` for cleaner conditionals
