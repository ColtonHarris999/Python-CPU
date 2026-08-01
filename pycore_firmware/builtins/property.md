# `property` — implementation plan

Status: **blocked** (stub in `property.py`)

## Goal

`property(fget, fset=None, fdel=None, doc=None)` builds a data descriptor.

## Blockers

1. **No descriptor protocol** on `LOAD_ATTR` / `STORE_ATTR` /
   `DELETE_ATTR` — hits return the raw dict value (or bind `CODE_OBJECT` as
   a method); they do not call `__get__` / `__set__`.
2. **No `OBK_PROPERTY` kind** to hold fget/fset/fdel pointers.
3. **Decorator syntax** `@property` uses the builtin at class-body execution
   time; module class folding currently rejects non-staticmethod decorators.

## Next steps

1. Add `OBK_PROPERTY` (fields: fget, fset, fdel).
2. Extend `LOAD_ATTR` / `STORE_ATTR` / `DELETE_ATTR` to invoke the accessors
   when the MRO hit is `OBK_PROPERTY`.
3. Extend `fold_module_classes` to accept `@property` / `.setter`.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | Object kind + heap alloc | object model |
| B | Attr FSM descriptor branch | A |
| C | Image class folding for `@property` | B |
| D | Firmware `property()` constructor allocating A | A, CALL of builtin/code |

## Recommendation

Descriptors are a hardware/attr-FSM feature; pure Python cannot polyfill
them without `__get__` invocation.
