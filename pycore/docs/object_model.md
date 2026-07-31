# PyCore Object Model

This document records the load-bearing decisions for general heap objects
under `PY_TAG_OBJECT`. It is the companion to `architecture.md` (traps /
mailbox) and `bytecode_support.md` (opcode tables).

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
| 4 | `MAX` | |
| 5 | `LIST_APPEND` | |
| 6 | `PRINT` | |
| 7 | `LEN` | |
| 8 | `RANGE` | Emits `PY_TAG_RANGE` |
| 9 | `SET` | Native empty / from-list-or-tuple constructor |

Image boot writes a third boot-record pair at `BOOT_RECORD_ADDR+64`: the
module **builtins** dict (`MUT_DICT`). The seeded builtins dict holds
`bytearray` / `max` / `len` / `print` / `range` / `set` as `OBK_BUILTIN`
handles and `int` as an `OBK_TYPE` whose `tp_dict` contains `from_bytes` /
`to_bytes`. Total boot record size is `BOOT_RECORD_BYTES = 96`.

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
3. Read `ob_head`. `OBK_INSTANCE`: probe `__dict__` (field0). `OBK_TYPE`:
   start the MRO at the type itself. Other kinds → `PY_TRAP_TYPE`.
4. On instance miss, walk `ob_type` → `tp_base` (depth guard 8), probing each
   `tp_dict`. Miss → `PY_TRAP_ATTR_ERROR` (15).
5. Writeback:
   - If the hit value is `OBJECT`/`OBK_BUILTIN` with `builtin_id=0`, unwrap
     `field1` as `CODE_OBJECT` and mark static (no `self` bind).
   - `method_flag = 0`: replace TOS; if source is TYPE and value is
     `CODE_OBJECT` (non-static), allocate `OBK_BOUND_METHOD`. Static → push
     the unwrapped `CODE_OBJECT`.
   - `method_flag = 1`: replace TOS with attr/func and push `self` or `NULL`
     (no allocation on this path). Static → `[func, NULL]`.

`STORE_ATTR` / `DELETE_ATTR` require `OBK_INSTANCE` and operate on `__dict__`
only (type mutation is build-time).

## Tooling

`HeapImageBuilder` in `pycore/tools/heap_image.py` provides:

- `alloc_instance` / `alloc_type` / `alloc_bound_method`
- `alloc_builtin` / `alloc_bytearray` / `alloc_exception` / `alloc_range`

Attribute image tests may still seed objects via:

```
# pycore-inject: SEED_TYPE T [attr=int ...]
# pycore-inject: SEED_INSTANCE o [type=T] [slots=N] [attr=int ...]
```

Real `class` statements are preferred for new coverage (`img_class_*`,
`img_staticmethod`). `run_image_test.py` mirrors seed pragmas with host
`SimpleNamespace` / `type` objects so differential `managed_entry()` still
works; host exec of real classes needs no seeding.

Python-side layout constants live in `pycore/tools/encoding.py`
(`OBK_*`, `pack_ob_head`, `obj_field_val_addr`). RTL mirrors are in
`pycore/rtl/pycore_defs.svh` (`PY_OBK_*`, `pycore_pack_ob_head`,
`pycore_obj_field_val_addr`).

Coverage: `pycore/tests/test_object_image.py`, `img_attr_*`, `img_class_*`.
