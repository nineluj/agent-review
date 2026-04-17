You are reviewing Python code. Apply these language-specific guidelines:

## Best Practices
- Prefer f-strings over .format() or % formatting
- Use type hints for function signatures (PEP 484)
- Use pathlib over os.path for filesystem operations
- Use context managers (with) for resource handling (files, locks, connections)
- Prefer list/dict/set comprehensions over map/filter with lambdas
- Use dataclasses or NamedTuple for structured data instead of plain dicts
- Use enum.Enum for fixed sets of constants instead of string literals

## Gotchas to Flag
- Mutable default arguments (def f(x=[]))
- Bare except clauses — must catch specific exceptions
- Using is/is not for value comparisons instead of ==/!=
- Late binding closures in loops (lambda capturing loop variable)
- Modifying a list/dict while iterating over it
- Missing await on coroutine calls in async code
- Using global or nonlocal without clear justification
- String concatenation in loops instead of join or list accumulation

## Anti-Patterns
- Catching Exception or BaseException and silently passing
- Nested try/except blocks that obscure control flow
- Star imports (from module import *)
- Using assert for runtime validation (stripped in optimized mode)
- Checking type with isinstance when duck typing would suffice
- Opening files without specifying encoding (Python 3 defaults vary by OS)
- Using threads for CPU-bound work instead of multiprocessing or async
