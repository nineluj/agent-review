# agent-review.el Specification

## Overview

An Emacs package that uses acp.el and agent-shell configurations to perform automated code reviews of git changes, displaying findings in a tabulated list interface.

## Purpose

Provide a non-interactive code review interface that:
- Analyzes current git changes (staged and unstaged)
- Uses AI agents via ACP protocol to identify issues
- Presents findings in a structured, navigable list

## Components

### 1. Git Integration

**Function:** `agent-review--get-git-changes`

**Responsibility:** Collect all git changes in the current repository

**Output:** Alist containing:
```elisp
((:staged . "diff text for staged changes")
 (:unstaged . "diff text for unstaged changes"))
```

**Implementation:**
- Use `git diff --cached` for staged changes
- Use `git diff` for unstaged changes
- Return both as strings

### 2. Agent Integration

**Function:** `agent-review--request-review`

**Responsibility:** Send changes to agent and get review results

**Input:**
- Git changes (from component 1)
- Agent config (from agent-shell)

**Process:**
1. Create temporary ACP client using config's `:client-maker`
2. Initialize session with `acp-make-initialize-request`
3. Start session with `acp-make-session-new-request`
4. Send review prompt with `acp-make-session-prompt-request`
5. Collect agent response
6. Shutdown client

**Prompt Template:**
```
Review the following git changes and identify issues. For each issue, provide:
- File path
- Line number (if applicable)
- Severity (error/warning/suggestion)
- Description

Format your response as a list where each issue is on its own line in this format:
FILE:LINE|SEVERITY|DESCRIPTION

Git changes:
{changes}
```

**Output:** Raw agent response text

### 3. Response Parser

**Function:** `agent-review--parse-issues`

**Responsibility:** Parse agent response into structured issue list

**Input:** Agent response text

**Output:** List of issue plists:
```elisp
((:file "path/to/file.el"
  :line 42
  :severity "error"
  :description "Variable `foo' is unused")
 ...)
```

**Parsing Strategy:**
- Look for lines matching pattern: `FILE:LINE|SEVERITY|DESCRIPTION`
- Extract and validate each component
- Handle cases where line number is not applicable (use 1 as default)
- Filter out non-issue text

### 4. Display Interface

**Mode:** `agent-review-mode` (derived from `tabulated-list-mode`)

**Buffer Name:** `*Agent Review*`

**Columns:**
1. Severity (width: 10) - color-coded
2. File (width: 30) - relative path
3. Line (width: 6) - right-aligned number
4. Description (width: remaining) - issue text

**Severity Colors:**
- `error`: red/error face
- `warning`: yellow/warning face  
- `suggestion`: blue/info face

**Key Bindings:**
- `RET` / `mouse-1`: Jump to issue location in file
- `q`: Quit review buffer
- `g`: Refresh/re-run review
- `n`: Next issue
- `p`: Previous issue

**Navigation Function:** `agent-review-jump-to-issue`

**Responsibility:** Open file at issue location

**Implementation:**
1. Get issue at point
2. Extract `:file` and `:line`
3. Use `find-file` to open file
4. Use `goto-line` to jump to location
5. Pulse/highlight the line briefly

## Entry Point

**Command:** `agent-review`

**Interactive Behavior:**
1. Check if in a git repository (error if not)
2. Prompt user to select agent config (from `agent-shell-agent-configs`)
3. Show progress message: "Collecting git changes..."
4. Collect changes
5. Show progress message: "Requesting review from {agent}..."
6. Send to agent
7. Parse response
8. Display in tabulated list buffer
9. Show completion message: "Review complete: {N} issues found"

**Non-interactive Behavior:**
Accept optional `:config` parameter to skip agent selection

## Dependencies

```elisp
;; Package-Requires: ((emacs "29.1") (acp "0.7.1") (agent-shell "0.17.2"))
```

## File Structure

```
agent-review/
├── SPEC.md              (this file)
├── agent-review.el      (main implementation)
└── README.md            (user documentation)
```

## Error Handling

- Git not found: Error with clear message
- Not in git repo: Error with clear message
- No changes to review: Info message, don't create buffer
- Agent connection fails: Error with agent-specific message
- Agent returns no parseable issues: Warning, create empty buffer with message
- File in issue doesn't exist: Warning when jumping, don't error

## Future Enhancements (Not in Initial Version)

- Per-issue interaction: Follow-up chat, request fix
- Filtering by severity
- Grouping by file
- Saving/loading review sessions
- Configuration for custom prompts
- Support for reviewing specific files/hunks only
