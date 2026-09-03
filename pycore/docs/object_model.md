# PyCore Object Model

This document records the load-bearing decisions for general heap objects
under `PY_TAG_OBJECT`. It is the companion to `architecture.md` (traps /
mailbox), `bytecode_support.md` (opcode tables), and `exception_support.md`
(which built-in exception types are seeded).

## D1 — Keep the 4-bit tag; kind under OBJECT

All 16 tag values are allocated. Widening `PYCORE_TAG_WIDTH` 4→5 ripples
through RF, dmem packing, every hex image, and every testbench.

**Decision:** `PY_TAG_OBJECT` (`4'b1010`) means *"heap object — read
`ob_head` for the kind."* Attribute and call paths pay one extra dmem read;
that is already a multi-cycle path. Lists/dicts/sets use `MUT_COLLEC`, not
`OBJECT`.

## D2 — Uniform header, tuple-element stride

```
Handle: { PY_TAG_OBJECT, {64'd0, obj_addr[63:0]} }

obj + 0   : ob_head (raw, untagged)
              [127:96] ob_kind    (PY_OBK_*)
              [95:64]  ob_flags
              [63:0]   ob_type    (byte addr of the TYPE object; 0 = none)
obj + 16  : { 124'b0, PY_TAG_OBJECT }   // self-tag, 32B stride
obj + 32  : field0 value      obj + 48 : field0 tag
...
```

Field *i* lives at `pycore_tuple_val_addr(obj, i+1)`. Call sites use
`pycore_obj_field_val_addr(obj, i)` / `obj_field_val_addr` in tooling.

| `OBK_*` | Value | field0 | field1 | field2 | Size |
| --- | --- | --- | --- | --- | --- |
| `INSTANCE` | 1 | `__dict__` (MUT_DICT) | — | — | 64 B |
| `TYPE` | 2 | `tp_dict` | `tp_base` | `tp_name` | 128 B |
| `BOUND_METHOD` | 3 | `__func__` | `__self__` | — | 96 B |
| `BUILTIN` | 4 | `builtin_id` (INT) | `bound_self` | — | 96 B |
| `BYTEARRAY` | 5 | legacy OBJECT kind; prefer `MUT_BYTEARRAY` | | | |
| `EXCEPTION` | 6 | `exc_type` | `args` (TUPLE) | — | 96 B |

`range` values use the dedicated `PY_TAG_RANGE` tag (not an OBJECT kind).

### Builtin ids (`PY_BI_*` / `BI_*`)

| Id | Name | Notes |
| --- | --- | --- |
| 0 | `STATICMETHOD` | Image-time `@staticmethod` wrapper; `bound_self` = CODE |
| 1 | `BYTEARRAY` | Constructor |
| 2 | `FROM_BYTES` | `int.from_bytes` |
| 3 | `TO_BYTES` | `int.to_bytes` |
| 4 | `MAX` | Two-arg INT/BOOL fast path in CALL FSM |
| 5 | `LIST_APPEND` | |
| 6 | `PRINT` | CALL → `PY_TRAP_BUILTIN_CALL` (excore) |
| 7 | `LEN` | Tag fast paths (LIST/TUPLE/DICT/SET/STR/inline RANGE); INSTANCE `__len__` via own `tp_dict` |
| 8 | `RANGE` | Emits `PY_TAG_RANGE` |
| 9 | `SET` | Native empty / from-list-or-tuple constructor |
| 10 | `ORD` | One-character STR → INT code point. Always SHORT_STR (any string ≤15 bytes is), so the UTF-8 decode reads the inline payload — one cycle, no `string_mem` access. Non-STR / not exactly one character / malformed UTF-8 → `TYPE` |
| 11 | `CHR` | INT code point → one-character SHORT_STR (1–4 UTF-8 bytes inline). Rejects > U+10FFFF, negatives, and lone surrogates (`TYPE`) |
| 12 | `HEAP_MARK` | Zero-arg; returns `heap_ptr_r` as `INT` |
| 13 | `HEAP_RELEASE` | Restores `heap_ptr_r`. Mark must be within `[HEAP_INIT_PTR, heap_ptr_r]`, else `MEM_FAULT` |
| 14 | `CODE_MARK` | Zero-arg; returns `code_ram_ptr_r` (a slot index) as `INT` |
| 15 | `CODE_RELEASE` | Restores `code_ram_ptr_r`. Mark must be within `[CODE_RAM_INIT_SLOT, code_ram_ptr_r]`, else `MEM_FAULT` |
| 16 | `EXEC_GLOBALS` | `_bi_exec_globals(code, dict)`: enter a `CODE_OBJECT` with `globals_base_r` pointed at a `MUT_DICT`. Wrong argc → `CALL_FILTER`; non-code / non-dict → `TYPE`. The caller's globals come back on RETURN. |

Image boot writes a third boot-record pair at `BOOT_RECORD_ADDR+64`: the
module **builtins** dict (`MUT_DICT`). The seeded builtins dict holds
`bytearray` / `max` / `len` / `_bi_print` / `range` / `set` / `ord` / `chr` /
`_bi_heap_mark` / `_bi_heap_release` / `_bi_code_mark` / `_bi_code_release` /
`_bi_exec_globals` as
`OBK_BUILTIN`
handles, `int` as an `OBK_TYPE` whose `tp_dict` contains `from_bytes` /
`to_bytes`, Wave A exception types as `OBK_TYPE` (`BaseException` →
`Exception` → leaves including `StopIteration` and `SyntaxError`; exception
`ob_flags` bit set; see `exception_support.md`), and ROM
firmware names (`print`, `sum`, `abs`, `bool`, `all`, `any`, `enumerate`,
`map`, `zip`, `exec`, `eval`, …) as `CODE_OBJECT` handles from `ROM_FIRMWARE_BUILTINS` in
`image_from_source.py`. Public `print` is the ROM wrapper; `_bi_print`
(`BI_PRINT`) is the one-arg `CONSOLE_TX` sink. The same `StopIteration`
handle is also written to the exc-arena sidecar at
`ITER_EXHAUST_TYPE_ADDR` (`0x1BFE0`) so `S_BOOT` can latch
`iter_exhaust_type_r` without probing the builtins dict. Total boot record
size is `BOOT_RECORD_BYTES = 96`.

**Resolution:** `LOAD_GLOBAL` / `LOAD_NAME` probe globals, then this
builtins dict (LEGB **B**). **CALL** on an `OBK_BUILTIN` handle dispatches
by `builtin_id` in the CALL FSM — hardware accelerates known tags (e.g.
`BI_LEN` reads list/tuple/dict/set/str/inline-range headers and calls
instance `__len__` when present). **CALL** on a ROM `CODE_OBJECT` uses the
normal frame path. Pure-Python bodies under `pycore_firmware/builtins/`
also cover miss / protocol cases (not for re-deriving header lengths in a
loop). See `planning/implemented/builtins_next_steps_plan.md`.

## D3 — `__dict__` is a real dict

Instance and class attributes are ordinary PyCore dicts with string keys.
Attribute lookup reuses `CP_DICT_PROBE` unchanged (hash, rich-eq, tombstones,
`PY_TRAP_DICT_GROW` → excore), including the insertion-order key sidecar.
No separate attribute-slot table.

## D4 — Method calls allocate nothing on the hot path

CPython 3.12+ `LOAD_ATTR` with `oparg & 1` pushes `[func, self]` (or
`[attr, NULL]`). Bound-method *objects* are only needed for the unbound form
`f = obj.method`. See M2/M3.

## D5 — Classes are built at image-build time

Module-level `class` idioms are recognized by `fold_module_classes` in
`image_from_source.py`, executed on the host, and emitted as fully-formed
`OBK_TYPE` objects. The class-creation bytecode span is rewritten in place to
`LOAD_CONST <_PyCoreTypeRef>` + `STORE_NAME` with **NOP padding** (never
compact — branch offsets stay valid). The class-body code const is replaced
with `None` so unsupported body plumbing (`LOAD_LOCALS`, `MAKE_CELL`, …) is
not serialized.

**Supported body:** plain methods, `@staticmethod`, and constant assignments
(`int`/`bool`/`str`/`None`). Rejected: bases, metaclasses, `__slots__`,
`@classmethod`, nested/dynamic `class`.

**staticmethod representation:** `tp_dict` entry is `OBK_BUILTIN` with
`builtin_id=0` and `bound_self` = the method `CODE_OBJECT` handle. `LOAD_ATTR`
unwraps this to a `CODE_OBJECT` and pushes `NULL` as the CALL sentinel (no
`self` bind). Ordinary methods remain bare `CODE_OBJECT` entries (bind on
`method_flag=1` / allocate `OBK_BOUND_METHOD` on `method_flag=0`).

Dynamic `LOAD_BUILD_CLASS` stays in `DEFERRED_OPS` for nested/runtime class
creation until frame-local namespaces exist.

## LOAD_ATTR algorithm (M2)

1. Resolve `co_names[namei]` (`namei = oparg >> 1`).
2. Receiver must be `PY_TAG_OBJECT`; else `PY_TRAP_TYPE`.
3. Read `ob_head`. Before any dict probe, SHORT_STR **special names**:

   | Name | Receiver | Result |
   | --- | --- | --- |
   | `__dict__` | `OBK_INSTANCE` / `OBK_TYPE` | field0 dict handle (`MUT_COLLEC`) |
   | `__class__` | `OBK_INSTANCE` | `ob_type` as `OBJECT` (TYPE_TRAP if 0) |
   | `__class__` | `OBK_TYPE` | the type itself (identity; not host `type`) |
   | `__base__` | `OBK_TYPE` | field1 `tp_base`, or `None` if unset/zero |
   | `__base__` | `OBK_INSTANCE` | fall through to normal probe (usually ATTR_ERROR) |

   Specials write back as **data** (replace TOS only; ignore `method_flag`).
4. Else `OBK_INSTANCE`: probe field0 dict. `OBK_TYPE`: start the MRO at the
   type itself. Other kinds → `PY_TRAP_TYPE`.
5. On instance miss, walk `ob_type` → `tp_base` (depth guard 8), probing each
   `tp_dict`. Miss → `PY_TRAP_ATTR_ERROR` (15).
6. Writeback:
   - If the hit value is `OBJECT`/`OBK_BUILTIN` with `builtin_id=0`, unwrap
     `field1` as `CODE_OBJECT` and mark static (no `self` bind).
   - `method_flag = 0`: replace TOS; if source is TYPE and value is
     `CODE_OBJECT` (non-static), allocate `OBK_BOUND_METHOD`. Static → push
     the unwrapped `CODE_OBJECT`.
   - `method_flag = 1`: replace TOS with attr/func and push `self` or `NULL`
     (no allocation on this path). Static → `[func, NULL]`.

`STORE_ATTR` / `DELETE_ATTR` require `OBK_INSTANCE` and operate on the instance
dict only (type mutation is build-time). The special names `__dict__` /
`__class__` / `__base__` are rejected with `PY_TRAP_TYPE` (no header mutation
via Python).

## Tooling

`HeapImageBuilder` in `pycore/tools/heap_image.py` provides:

- `alloc_instance` / `alloc_type` / `alloc_bound_method`
- `alloc_builtin` / `alloc_bytearray` / `alloc_exception` / `alloc_range`

Attribute image tests may still seed objects via:

```
# pycore-inject: SEED_TYPE Base
# pycore-inject: SEED_TYPE Child base=Base [attr=int ...]
# pycore-inject: SEED_INSTANCE o [type=Child] [slots=N] [attr=int ...]
# pycore-inject: SEED_CODE name [mode=exec|eval] source="<text>"
```

`SEED_CODE` host-`compile()`s `source` in `mode`, validates it with
`validate_code_tree`, serializes it like any other code object (its bytecode
joins the same imem pool), and binds the handle to `name` in module globals.
That is how a program gets a precompiled `CODE_OBJECT` to hand to `exec` /
`eval` before runtime `compile()` exists. `\n` / `\t` escapes are expanded;
`source=` comes last and is quoted, so it may contain spaces and `=`.

`base=` must name an earlier `SEED_TYPE` (declaration order = allocation
order). Real `class` statements are preferred for new coverage (`img_class_*`,
`img_staticmethod`) but still reject explicit bases at fold time.
`run_image_test.py` mirrors seed pragmas with host `type(name, bases, body)` /
`SimpleNamespace` so differential `managed_entry()` still works.

Python-side layout constants live in `pycore/tools/encoding.py`
(`OBK_*`, `pack_ob_head`, `obj_field_val_addr`). RTL mirrors are in
`pycore/rtl/pycore_defs.svh` (`PY_OBK_*`, `pycore_pack_ob_head`,
`pycore_obj_field_val_addr`).

Coverage: `pycore/tests/test_object_image.py`, `img_attr_*`, `img_class_*`.
