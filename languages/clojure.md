You are reviewing Clojure code. Apply these language-specific guidelines:

## Best Practices
- Use destructuring in function arguments and let bindings
- Prefer threading macros (-> ->>) over deeply nested calls
- Use keywords as map accessors (:key m) instead of (get m :key) when appropriate
- Use when instead of (if x y nil) and when-not instead of (if (not x) y nil)
- Prefer map/filter/reduce over explicit recursion for collection processing
- Use protocols and multimethods for polymorphism instead of cond on type
- Use spec (clojure.spec.alpha) or malli for data validation at boundaries
- Prefer pure functions — isolate side effects to the edges of the system

## Gotchas to Flag
- Lazy sequence realization inside dosync or locking (can cause deadlocks)
- Holding onto the head of a lazy sequence (memory leaks)
- Using def inside functions (creates global vars — use let instead)
- Reflection warnings — missing type hints on Java interop calls
- Using atoms/refs where a simple let binding would suffice
- Swapping on an atom with side effects in the swap function (may retry)
- Using concat without doall when the result must be realized immediately
- Comparing floats with = instead of a tolerance-based comparison

## Anti-Patterns
- Large deeply nested let blocks — break into smaller functions
- Using str for building large strings in loops instead of StringBuilder or join
- Overusing macros where functions would work (macros don't compose with HOFs)
- Using dynamic vars (*earmuffs*) for passing data through call stacks — prefer explicit arguments
- Ignoring return values of swap!/send/alter (swallowing errors silently)
- Using Thread/sleep in core.async go blocks (blocks the thread pool)
- Raw Java interop when a Clojure wrapper library exists (e.g., clj-http vs HttpClient)
