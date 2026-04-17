You are reviewing code in a language without a specific review profile. Apply these general guidelines:

## Best Practices
- Functions should have a single clear responsibility
- Prefer immutable data and pure functions where the language supports it
- Handle errors explicitly — do not silently ignore failures
- Use descriptive names for variables, functions, and types
- Prefer early returns to reduce nesting depth
- Keep functions short and focused — extract helpers when logic is complex

## Gotchas to Flag
- Unhandled error cases or missing error propagation
- Resource leaks (files, connections, memory) — ensure proper cleanup
- Off-by-one errors in loops and index access
- Race conditions in concurrent or async code
- Hardcoded secrets, credentials, or environment-specific values
- Integer overflow or division by zero without guards

## Anti-Patterns
- Dead code or unreachable branches
- Duplicated logic that should be extracted into a shared function
- Magic numbers or string literals without named constants
- Overly broad exception/error catching that masks bugs
- Deep nesting (more than 3-4 levels) — flatten with early returns or extraction
- Mixing concerns (I/O, business logic, presentation) in a single function
