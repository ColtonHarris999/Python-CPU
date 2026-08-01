# `super` — implementation plan

Status: **blocked** (stub in `super.py`)

## Goal

`super()` / `super(typ, obj)` returns a proxy that delegates attribute
lookup to the next class in the MRO.

## Blockers

1. **`LOAD_SUPER_ATTR` deferred** in `image_from_source.py` /
   `bytecode_support.md`.
2. **Zero-arg `super()`** needs cell/`__class__` closure binding from the
   compiler — closures are rejected by image tooling.
3. **Proxy object kind** with custom `LOAD_ATTR` behaviour does not exist
   (LOAD_ATTR only handles INSTANCE / TYPE / staticmethod unwrap).

## Next steps

1. Implement `LOAD_SUPER_ATTR` in decode + attr FSM (MRO start = next after
   `typ`).
2. Image-fold explicit `super(Cls, self).method(...)` before zero-arg form.
3. Add `OBK_SUPER` proxy only if unbound `s = super(...)` must work.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | Hardware `LOAD_SUPER_ATTR` for `super(Cls, self).attr` | MRO walk (exists) |
| B | Image rewrite of zero-arg `super()` to explicit form | class folding |
| C | Optional `OBK_SUPER` for proxy objects | A |

## Recommendation

Prefer hardware `LOAD_SUPER_ATTR` over a pure-Python `super` builtin; the
builtin alone cannot intercept subsequent `LOAD_ATTR`.
