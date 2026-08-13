# CO_VARKEYWORDS + positional-only CALL parity

**Branch:** `cursor/co-varkeywords-1400`  
**Goal:** Make callee `**kwargs` packing and `/` positional-only binding match
CPython 3.14 so CALL / CALL_KW / CALL_FUNCTION_EX behave like standard Python
for user `CODE_OBJECT` callables.

---

## 1. Changes

### 1.1 Code-object metadata schema

Packed metadata (`CODE_FIELD_METADATA`) now includes:

| Bits | Field |
| --- | --- |
| `[15:0]` | `argcount` (unchanged) |
| `[31:16]` | `nlocals` (unchanged) |
| `[47:32]` | `stacksize` (unchanged) |
| `[63:48]` | `kwonlyargcount` (unchanged) |
| `[64]` | `CO_VARARGS` (unchanged) |
| `[65]` | `CO_VARKEYWORDS` (**new**) |
| `[81:66]` | `posonlyargcount` (**new**) |

Tooling / RTL:

- `pack_code_metadata` / `unpack_code_metadata` (`pycore/tools/encoding.py`)
- `HeapImageBuilder.add_code_object` + `image_from_source.serialize_code`
- `validate_code_object` no longer rejects `CO_VARKEYWORDS`
- RTL helpers `pycore_code_meta_varkeywords` /
  `pycore_code_meta_posonlyargcount` (`pycore/rtl/pycore_defs.svh`)

### 1.2 CALL binder (`pycore_call_fsm.svh`)

- Phase 6 latches varkw + posonly bits and **forces the shared binder** whenever
  the callee declares `**kwargs`, so even a purely positional call installs an
  (empty) kwargs dict local.
- Keyword match against a **positional-only** formal is treated as unexpected
  (same as CPython): with `**kwargs` it is packed; without it → `CALL_FILTER`.
- Unexpected non-posonly keywords: leftover bitmask when `CO_VARKEYWORDS`, else
  `CALL_FILTER`.
- Duplicate binding (positional already filled + same name as keyword) still
  traps even when `**kwargs` is present — leftovers must not swallow duplicates.
- Subs **52–55**: allocate a dict **pre-sized** for the caller keyword count
  (no `DICT_GROW`), insert leftovers in call order, publish used/order_len,
  install as the local after positionals / kw-only / `*args`, and bump
  `call_argcount` so phase-7 UNINIT clear does not wipe the packed dict.
- Keyword scratch RF region sits above `*args` and `**kwargs` locals.

### 1.3 Related CALL holes closed

1. **`co_posonlyargcount`:** Without serializing / enforcing `/`, `f(a, /)`
   incorrectly accepted `f(a=1)`. That is now metadata + binder behavior
   (trap without varkw; pack with varkw).
2. **Method-form `CALL_KW` kwargs source:** Incoming keyword values were read
   from `locals[n_pos + i]`, which is correct for free functions but wrong for
   bound methods where `self` occupies `locals[0]` and kwargs start at
   `locals[argcount + i]` (`argcount == n_pos + 1`). Scratch base now uses
   `argcount + n_kwargs` for the same reason. Covered by `img_method_call_kw`
   and `img_varkw_method`.

---

## 2. Explicit non-goals / remaining limits

These are intentional or pre-existing binder limits, not regressions from this
work:

| Item | Status |
| --- | --- |
| `OBK_BUILTIN` / TYPE kwargs | Still `CALL_FILTER`; use ROM firmware `CODE_OBJECT` |
| Rich `TypeError` objects | Fatal `CALL_FILTER` (trap 6), same as other CALL errors |
| Leftover keyword index mask | 128 bits (matches existing 7-bit kwargs walk) |
| Contaminated / non-string EX kwargs keys | Still trap on bind (string names required) |

---

## 3. Tested behavior

Host goldens come from CPython 3.14 via `run_image_test.py`; HW checks the same
`EXPECTED_TAG` / `EXPECTED_VALUE` (or `EXPECT_TRAP` for negative cases).

### 3.1 Unit (`ImageTranscodingTest`)

- Metadata pack/unpack round-trip for varkw + posonly bits
- `validate_code_object` allows `**kwargs` and `/`
- Serialized code objects preserve `CO_VARARGS` + `CO_VARKEYWORDS` +
  `posonlyargcount`

### 3.2 Image programs (Makefile → `pycore-img-call-all`)

| Target | Behavior under test | Host expectation |
| --- | --- | --- |
| `varkw_basic` | Leftover kwargs packed; values readable | `26` |
| `varkw_empty` | Empty `**k` on argc=0 / positional-only calls | `16` |
| `varkw_only` | Kwargs-only formal | `43` |
| `varkw_and_varargs` | `*args` + `**kwargs` scratch / slot layout | `130` |
| `varkw_call_ex` | `CALL_FUNCTION_EX` + packing (incl. empty `**{}`) | `11` |
| `varkw_posonly` | `/` + `**kwargs`: keyword of posonly name → dict | `244` |
| `posonly_ok` | `/` without varkw; normal kwargs still bind | `87` |
| `posonly_kw_trap` | `/` without varkw; keyword for posonly → trap 6 | trap |
| `varkw_name_collision` | Keyword named `args` goes to kwargs, not `*args` | `15` |
| `varkw_no_wipe` | Phase-7 must not wipe packed / empty kwargs dict | `9` |
| `varkw_many` | Many leftovers; pre-sized dict, no grow | `8` |
| `varkw_kwonly` | Kw-only defaults + leftover packing | `16` |
| `varkw_combo` | defaults + `*args` + kw-only + `**kwargs` | `1628` |
| `varkw_method` | Bound method `self` + `**kwargs` | `13` |
| `method_call_kw` | Bound method + CALL_KW without varkw (self/kw slot hole) | `55` |
| `varkw_dup_trap` | `f(1, a=2)` with `**k` still duplicate → trap 6 | trap |
| `varkw_kwonly_missing_trap` | Required kw-only missing w/ extras → trap 6 | trap |

Regression: existing defaults / `CALL_KW` / `CALL_FUNCTION_EX` / `CO_VARARGS` /
method targets remain in `pycore-img-call-all`.

---

## 4. Files touched

- RTL: `pycore/rtl/pycore_call_fsm.svh`, `pycore_core.sv`, `pycore_defs.svh`
- Tooling: `encoding.py`, `heap_image.py`, `image_from_source.py`
- Tests: `pycore/tests/test_image_from_source.py`, `pycore/programs/img_varkw_*`,
  `img_posonly_*`, Makefile wiring
- Docs: this file; `pycore/docs/bytecode_support.md`; plan status notes
