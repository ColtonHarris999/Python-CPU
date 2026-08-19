# `exec` — implementation plan

Status: **blocked** (stub in `exec.py`)

**Full step-by-step plan:** [`planning/compile_exec_plan.md`](../../planning/compile_exec_plan.md)
(§8 phase 3 for the code-object form, §13 for the string form). Note that
`exec(code_object)` needs **no hardware change**: `CALL` on a `CODE_OBJECT` in a
variable already works, and `STORE_NAME` / `LOAD_NAME` already target the module
globals dict.

## Goal

`exec(object, globals=None, locals=None)` runs statements from a string or
code object for side effects (returns `None`).

## Blockers

Same spine as `eval.md`, plus:

1. **Statement code objects** (`mode="exec"`) may use opcodes still rejected
   by image validation (`STORE_NAME` is OK; imports, `try`, `class`, `with`
   are not).
2. **Return value protocol** — `exec` must discard TOS / ignore
   `RETURN_VALUE` from the body differently than a normal CALL site.
3. **Closure / cell support** for nested defs inside exec'd source — out of
   scope (`MAKE_FUNCTION` defaults-only folding).

## Next steps

1. Share the `eval` trampoline; wrap to always return `None`.
2. Validate exec'd code objects against the same `SUPPORTED_OPS` set as
   image-boot modules.
3. Defer string input until `compile.md` phase C/D.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | `exec(code)` → call trampoline → pop result → `None` | `eval.md` A |
| B | globals override | `eval.md` B |
| C | string form | `compile.md` C/D |

## Recommendation

Treat `exec` as a thin wrapper over the eval trampoline; do not duplicate
compiler work.
