# `eval` — implementation plan

Status: **blocked** (stub in `eval.py`)

**Full step-by-step plan:** the code-object form and the `globals=` override are
[`planning/code_loading_bios_tokenizer_plan.md`](../../planning/code_loading_bios_tokenizer_plan.md)
§8 (Plan 1); the string form is
[`planning/native_compiler_plan.md`](../../planning/native_compiler_plan.md)
§8.1 (Plan 2).

## Goal

`eval(expression, globals=None, locals=None)` evaluates an expression from a
string or code object and returns the result.

## Blockers

1. **`compile` unavailable** for string input (see `compile.md`).
2. **No `CALL` of arbitrary code objects with a swapped globals dict.**
   `CALL` enters a frame using the callee code object's linked module
   globals; there is no API to run a code object under caller-supplied
   mappings.
3. **`locals` dict execution model** needs frame-local namespaces
   (`LOAD_NAME` currently equals globals-then-builtins only).
4. **Keyword / optional args** need `CALL_KW` or default-only signatures.
5. **Exception propagation** for raise-during-eval needs exception handling
   opcodes (deferred).

## Next steps

1. Restrict the firmware contract to `eval(code_object)` where `code_object`
   is a preloaded `PY_TAG_CODE_OBJECT` (expression mode, `co_flags` clear).
2. Add a CALL variant or trampoline: "invoke code object with explicit
   globals handle" (boot-record style pointer).
3. Wire string form only after `compile.md` phase C/D.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | `eval(code)` trampoline: push NULL + CALL code object, return TOS | CALL of CODE_OBJECT |
| B | Optional globals override in trampoline | frame globals pointer rewrite |
| C | `eval(str)` via compile blob loader | `compile.md` C/D |
| D | locals dict + `LOAD_NAME` locals chain | frame locals model |

## Recommendation

Ship phase A as a tiny pure-Python / ROM helper once code objects can appear
in the builtins dict. Leave string `eval` blocked with `compile`.
