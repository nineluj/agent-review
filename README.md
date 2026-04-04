# agent-review.el

## Overview
https://github.com/user-attachments/assets/8ad86c2d-a91e-4f69-b51a-0f7f72ae0b19

`agent-review` enables a streamlined workflow: use one AI agent (Claude, Cursor, Gemini) to implement features, then instantly get a second opinion from a different agent. The package automatically collects your git changes and sends them to your chosen AI agent for review. The cross-agent review catches issues that single-agent workflows miss, while the tight feedback loop means you fix problems quicker and more efficiently.

All findings display in a navigable list interface where you can jump to issues, triage by severity, and send fixes back to your implementation agent—closing the loop without leaving Emacs.

## Requirements

- Emacs 29.1 or later
- [acp.el](https://github.com/xenodium/acp.el) >= 0.7.1
- [agent-shell](https://github.com/xenodium/agent-shell) >= 0.16.2
- Git
- An ACP-compatible agent (Claude Code, Cursor, Gemini CLI, etc.)

This package builds on the excellent work by [xenodium](https://github.com/xenodium) on acp.el and agent-shell. Consider [supporting their work](https://github.com/sponsors/xenodium)!

For setting up individual agents (Claude Code, Cursor, Gemini CLI, etc.), follow the [agent-shell setup guide](https://github.com/xenodium/agent-shell?tab=readme-ov-file#setup).

## Installation

### Using straight.el

```elisp
(straight-use-package
 '(agent-review :type git :host github :repo "nineluj/agent-review"))
```

### Using Doom Emacs

Add to your `packages.el`:

```elisp
(package! agent-review
  :recipe (:host github
           :repo "nineluj/agent-review"
           :files ("*.el")))
```

### Manual

Clone this repository and add to your load path:

```elisp
(add-to-list 'load-path "/path/to/agent-review")
(require 'agent-review)
```

## Usage

### Basic Usage

1. Make some changes in a git repository
2. Run `M-x agent-review`
3. Select an agent from the list
4. Wait for the review to complete
5. Browse issues in the `*Agent Review*` buffer

### Key Bindings (in review buffer)

| Key   | Action                                |
|-------|---------------------------------------|
| RET   | Jump to issue location                |
| g     | Refresh (re-run review)               |
| q     | Quit review buffer                    |
| n     | Next line                             |
| p     | Previous line                         |
| m     | Mark issue at point                   |
| u     | Unmark issue at point                 |
| M     | Mark all issues                       |
| U     | Unmark all issues                     |
| W     | Copy marked issues to kill ring       |
| S     | Send marked issues to agent-shell     |

### Programmatic Usage

```elisp
;; Use a specific agent configuration
(agent-review (agent-shell-anthropic-make-claude-code-config))
```

## Configuration

### Default Agent

Set a preferred agent to skip the selection prompt:

```elisp
(setq agent-shell-preferred-agent-config
      (agent-shell-anthropic-make-claude-code-config))
```

### Git Executable

If git is not in your PATH:

```elisp
(setopt agent-review-git-executable "/path/to/git")
```

## How It Works

1. **Collection**: Runs `git diff` and `git diff --cached` to get changes
2. **Analysis**: Sends changes to AI agent with structured prompt
3. **Parsing**: Extracts issues in format `FILE:LINE|SEVERITY|DESCRIPTION`
4. **Display**: Shows results in tabulated-list-mode with color-coding

## Example Output

```
  Severity    File                Line  Description
────────────────────────────────────────────────────────────────
  error       src/main.el           42  Variable 'unused-var' is defined but never used
* warning     lib/utils.el          15  Function docstring is missing
  suggestion  tests/test.el          8  Consider adding edge case test
```

(Issues can be marked with `m` for batch operations)

## Troubleshooting

### "Not in a git repository"

Run `agent-review` from within a git repository.

### "No git changes to review"

Make some changes first (either stage them or leave them unstaged).

### "Git executable not found"

Install git or configure `agent-review-git-executable`.

### No issues found but changes exist

The agent may not have found any issues, or the response parsing failed. Check the agent's actual response format.

## Fork Changes

This fork adds the following features on top of the upstream `nineluj/agent-review`:

### Custom language prompts
- Set `agent-review-language-prompts-directory` to load your own prompt files before built-in ones
- Lookup order: custom dir (language-specific, then `other.md`) -> built-in `languages/` dir
- Keep personal review directives out of the repo (e.g. `~/.doom.d/directives/`)

### Language-aware reviews
- Automatic programming language detection (Python, Clojure, TypeScript, or generic)
- Language-specific review prompts loaded from `languages/*.md` files
- Two-turn review: first detects language, then sends a tailored review prompt

### Rich diagnostics
- Issues now have both a **short description** (shown in the list) and a full **diagnostic** explanation
- New diagnostic buffer (`e` key) renders the full diagnostic in a bottom side window with markdown formatting, hard-wrapped at 80 columns
- Navigate between diagnostics with `n`/`p`, jump to file with `RET`, investigate with `I`

### Full file context
- Sends full file contents with line numbers alongside diffs, so the agent can report accurate line numbers instead of defaulting to 1

### Animated progress feedback
- Spinner animation with elapsed time while the review is in progress
- Per-buffer progress state so concurrent reviews each have independent timers

### Project-scoped buffers
- Review buffers are named per-project: `*Agent Review @ project-name*`
- Diagnostic buffers are similarly scoped: `*Agent Review Diagnostic @ project-name*`
- Supports projectile, project.el, and falls back to directory name

### Concurrent review safety
- All session state (status buffer, progress timer, buffer names) is captured in closures and buffer-local variables instead of globals
- Running two reviews in different projects no longer overwrites each other's buffers

### Agent-shell session guard
- `agent-review` requires an existing `agent-shell` session for the project
- Clear error message if no session exists: "Start one first with M-x agent-shell"

### Review list manager
- `M-x agent-review-list-reviews` (or `l` in review buffer) opens a bottom side window listing all review buffers with their status
- Click or `RET` to jump to a review; `g` to refresh the list
- Mouse support with highlight on hover

### Evil mode support
- Full evil normal-state keybindings for review, diagnostic, and list modes
- `gr` for refresh (avoids shadowing `gg`/`G`)

### PR review by URL
- `M-x agent-review-pr` (or `SPC q p`) reviews a GitHub Pull Request by URL
- Fetches the diff via `gh` CLI, sends full file context from the locally checked-out branch
- Requires the PR branch checked out locally and an agent-shell session open

### Investigate workflow
- `I` in the diagnostic buffer prompts for a question, then sends it to agent-shell with the diagnostic as context

## Contributing

Issues and pull requests welcome at https://github.com/nineluj/agent-review

## License

GPL-3.0-or-later
