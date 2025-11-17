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

## Contributing

Issues and pull requests welcome at https://github.com/nineluj/agent-review

## License

GPL-3.0-or-later
