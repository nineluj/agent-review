# agent-review.el

AI-powered code review for git changes using ACP (Agent Client Protocol).

## Overview

`agent-review` analyzes your staged and unstaged git changes using AI agents (Claude Code, Cursor, Gemini, etc.) and displays findings in a navigable list interface.

## Features

- Non-interactive code review (just shows results, no chat)
- Reviews both staged and unstaged changes together
- Displays issues by severity: error, warning, suggestion
- Jump directly to issue locations in files
- Uses agent-shell's configuration system
- Works with any ACP-compatible agent

## Requirements

- Emacs 29.1 or later
- [acp.el](https://github.com/xenodium/acp.el) >= 0.7.1
- [agent-shell](https://github.com/xenodium/agent-shell) >= 0.17.2
- Git
- An ACP-compatible agent (Claude Code, Cursor, Gemini CLI, etc.)

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

| Key   | Action                      |
|-------|-----------------------------|
| RET   | Jump to issue location      |
| g     | Refresh (re-run review)     |
| q     | Quit review buffer          |
| n     | Next line                   |
| p     | Previous line               |

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
(setq agent-review-git-executable "/path/to/git")
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
warning     lib/utils.el          15  Function docstring is missing
suggestion  tests/test.el          8  Consider adding edge case test
```

## Troubleshooting

### "Not in a git repository"

Run `agent-review` from within a git repository.

### "No git changes to review"

Make some changes first (either stage them or leave them unstaged).

### "Git executable not found"

Install git or configure `agent-review-git-executable`.

### No issues found but changes exist

The agent may not have found any issues, or the response parsing failed. Check the agent's actual response format.

## Future Enhancements

Planned features for future versions:

- Per-issue interaction (follow-up chat, request fixes)
- Filter by severity
- Group by file
- Save/load review sessions
- Custom review prompts
- Review specific files/hunks only

## Contributing

Issues and pull requests welcome at https://github.com/nineluj/agent-review

## License

GPL-3.0-or-later
