You are reviewing TypeScript code. Apply these language-specific guidelines:

## Best Practices
- Use strict TypeScript (strict: true in tsconfig) — avoid any unless truly necessary
- Prefer unknown over any for values of uncertain type, then narrow with type guards
- Use discriminated unions (tagged unions) for state modeling over optional fields
- Prefer const assertions (as const) for literal types and readonly data
- Use readonly for arrays and object properties that should not be mutated
- Prefer interfaces for object shapes that may be extended, type for unions/intersections
- Use nullish coalescing (??) and optional chaining (?.) instead of manual null checks
- Prefer async/await over raw Promise chains for readability

## Gotchas to Flag
- Using == instead of === (loose equality coercion)
- Type assertions (as T) that bypass the type checker without runtime validation
- Non-null assertions (x!) used to silence the compiler without verifying the value
- Floating promises — async calls without await, .catch(), or void operator
- Index signature access without undefined check (obj[key] may be undefined)
- Using delete on objects (creates deoptimized hidden classes in V8)
- Enum values used in comparisons without exhaustive checks (missing switch cases)
- Accidentally creating type: any through generic inference failures

## Anti-Patterns
- Using any to fix type errors instead of properly typing the code
- Exporting mutable state from modules
- Deeply nested ternaries or nullish chains — extract into named variables or functions
- Using Object, Function, or {} as types (too broad to be useful)
- Type casting through unknown (value as unknown as TargetType) to force incompatible types
- Mixing callback and promise patterns in the same API
- Ignoring the return type of .map()/.filter() (collecting results that are never used)
- Using string enums when a union of string literals would be simpler and more type-safe
