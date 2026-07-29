# PyCore Object Model

This document records the load-bearing decisions for general heap objects
under `PY_TAG_OBJECT`. It is the companion to `architecture.md` (traps /
mailbox) and `bytecode_support.md` (opcode tables).

## D1 — Keep the 4-bit tag; kind under OBJECT

All 16 tag values are allocated. Widening `PYCORE_TAG_WIDTH` 4→5 ripples
through RF, dmem packing, every hex image, and every testbench.

**Decision:** `PY_TAG_OBJECT` (`4'b1000`) means *"heap object — read
`ob_head` for the kind."* Attribute and call paths pay one extra dmem read;
that is already a multi-cycle path.

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
| `INSTANCE` | 1 | `__dict__` (DICT) | — | — | 64 B |
| `TYPE` | 2 | `tp_dict` | `tp_base` | `tp_name` | 128 B |
| `BOUND_METHOD` | 3 | `__func__` | `__self__` | — | 96 B |
| `BUILTIN` | 4 | `builtin_id` (INT) | `bound_self` | — | 96 B |
| `BYTEARRAY` | 5 | `length` | `buf_addr` | `capacity` | 128 B |
| `EXCEPTION` | 6 | `exc_type` | `args` (TUPLE) | — | 96 B |

## D3 — `__dict__` is a real DICT

Instance and class attributes are ordinary PyCore dicts with string keys.
Attribute lookup reuses `CP_DICT_PROBE` unchanged (hash, rich-eq, tombstones,
`PY_TRAP_DICT_GROW` → excore). No separate attribute-slot table.

## D4 — Method calls allocate nothing on the hot path

CPython 3.12+ `LOAD_ATTR` with `oparg & 1` pushes `[func, self]` (or
`[attr, NULL]`). Bound-method *objects* are only needed for the unbound form
`f = obj.method`. See M2/M3.

## D5 — Classes are built at image-build time

Module-level `class` idioms are recognized by `image_from_source.py`, executed
on the host, and emitted as fully-formed `OBK_TYPE` objects. Dynamic
`LOAD_BUILD_CLASS` stays in `DEFERRED_OPS` until frame-local namespaces exist.

## Tooling

`HeapImageBuilder` in `pycore/tools/heap_image.py` provides:

- `alloc_instance` / `alloc_type` / `alloc_bound_method`
- `alloc_builtin` / `alloc_bytearray` / `alloc_exception`

Python-side layout constants live in `pycore/tools/encoding.py`
(`OBK_*`, `pack_ob_head`, `obj_field_val_addr`). RTL mirrors are in
`pycore/rtl/pycore_defs.svh` (`PY_OBK_*`, `pycore_pack_ob_head`,
`pycore_obj_field_val_addr`).

Coverage: `pycore/tests/test_object_image.py`.
