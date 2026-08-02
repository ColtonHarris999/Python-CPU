# Builtins agent — next steps (post bytecode milestone)

**Audience:** agent finishing / integrating `pycore_firmware/builtins/`  
**Completed by bytecode agent:** see §1  
**Constraint:** stay positional-only until `CALL_KW` / `CALL_FUNCTION_EX` unfreeze

Related:

- Prior bytecode plan (implemented): `planning/builtins_bytecode_support_plan.md`
- Inventory: `pycore_firmware/builtins/builtins.md`
- Opcode matrix: `pycore/docs/bytecode_support.md`

---

## 1. What the bytecode agent shipped

Hardware / tooling now supports the acceptance items from
`builtins_bytecode_support_plan.md` §6:

| Item | Status |
| --- | --- |
| LEGB-B tests (fallback, shadow, null bit, LOAD_NAME) | Done — `img_builtins_*`, `img_load_name_builtin` |
| `BI_LEN` LONG_STR + inline RANGE | Done |
| `BI_LEN` INSTANCE `__len__` via own `tp_dict` | Done — miss → `ATTR_ERROR` (15) |
| `RAISE_VARARGS` oparg 1 → fatal `PY_TRAP_RAISE` (17) | Done |
| `TO_BOOL` for `None` + containers | Done — `CONT_TO_BOOL` |
| Comprehension `RERAISE` policy | Documented as **option C** (avoid comps) |
| `CALL_KW` / `CALL_FUNCTION_EX` | **Frozen** positional-only in `builtins.md` |
| `tuple(iterable)` path | `UNPACK_EX` + `CALL_INTRINSIC_1` LIST_TO_TUPLE |
| `return True/False/None` on 3.14 | OK (`RETURN_CONST` absent; `img_return_true`) |
| Docs synced | `bytecode_support.md`, `architecture.md`, `builtins.md` |

---

## 2. Immediate builtins-agent work

1. **Replace `% 0` error hacks** with `raise <int-or-object>` where the
   intent is “fatal error” (`tuple.py` already uses LIST_TO_TUPLE; sweep
   `range.py`, `iter.py`, `next.py`, etc.).
2. **Rewrite firmware bodies** that assumed old TO_BOOL limits — `all` /
   `any` / `bool` / `filter(None, …)` can rely on None/container truthiness.
3. **Keep signatures positional-only** (freeze). Do not add `key=`, `sep=`,
   `*args` until bytecode unfreezes `CALL_KW` / `CALL_FUNCTION_EX`.
4. **Seed ROM `CODE_OBJECT`s** into the boot-record builtins dict for
   Python-only names (`sum`, `sorted`, `enumerate`, …) while leaving
   `len`/`max`/`range`/`set` as `BI_*` hybrid entries
   (`image_from_source.build_builtins_dict`).
5. **Wire `pycore_firmware/builtins/*.py` into image build** — compile each
   module, place handles in the builtins dict, and add differential image
   tests that call firmware builtins (not only `BI_*`).
6. **Update per-builtin status** in `builtins.md` as modules move from
   `implemented` → `in ROM`.

---

## 3. Follow-ups that still need bytecode help

Track these; do not invent custom opcodes:

| Need | Why |
| --- | --- |
| `CALL_KW` + `CALL_FUNCTION_EX` | Unfreeze `print`/`max`/`sorted`/`open` kwargs and varargs |
| Full exception tables / `RERAISE` | Real `TypeError`/`StopIteration`; comprehension option A/B |
| `BI_LEN` tuple-mode RANGE + OBJECT `__bool__` | Complete truthiness / len protocol |
| `GET_ITER`/`FOR_ITER` on OBJECT (`__iter__`/`__next__`) | Iterator protocol for user types |
| `BI_ORD` / `BI_CHR` | Unblock `ord`/`chr` / `ascii` |
| `LOAD_SUPER_ATTR` + descriptors | `super` / `property` / `classmethod` |
| `COMPARE_OP` string ordering | `sorted`/`min`/`max` on str |
| `FORMAT_*` / `BUILD_STRING` | Richer `str`/`format`/`print` |

---

## 4. Suggested order for the builtins agent

1. Image-seed a small ROM subset (`sum`, `abs`, `bool`, `all`, `any`) beside
   existing `BI_*` entries; add `img_firmware_*` tests.  
2. Sweep error paths to `raise`.  
3. Finish list-materializing iterators (`enumerate`/`zip`/`map`) against
   widened `TO_BOOL` + LIST_TO_TUPLE.  
4. Document remaining blocked builtins against §3 bytecode gaps.  
5. Only then ask bytecode for `CALL_KW` / exceptions / `ORD`/`CHR`.

---

## 5. Out of scope (unchanged)

- Host `compile` / full `eval`/`exec` of source  
- Filesystem `open`  
- Async (`aiter`/`anext`)  
- Custom opcodes outside CPython 3.14’s set  
