# Builtins agent — next steps (post CALL_KW)

**Audience:** agent finishing / integrating `pycore_firmware/builtins/`  
**Completed by bytecode agent:** see §1  
**Unblock:** `CALL_KW` / `CALL_FUNCTION_EX` / empty-dest `DICT_MERGE` are live for
`CODE_OBJECT` callees — kwargs / varargs ROM signatures are now allowed.

Related:

- CALL_KW plan (implemented): `planning/call_kw_support_plan.md`
- Prior bytecode plan: `planning/builtins_bytecode_support_plan.md`
- Inventory: `pycore_firmware/builtins/builtins.md`
- Opcode matrix: `pycore/docs/bytecode_support.md`

---

## 1. What the bytecode agent shipped

| Item | Status |
| --- | --- |
| LEGB-B / `BI_LEN` / `TO_BOOL` / `RAISE` / LIST_TO_TUPLE | Done (prior milestone) |
| Code-object fields `co_varnames`, `kwonlyargcount`, `co_kwdefaults` | Done |
| Shared CALL binder + `CALL_KW` → `CODE_OBJECT` | Done — `img_call_kw*` |
| `CALL_FUNCTION_EX` EX-A (`*args`, NULL kwargs) LIST/TUPLE | Done — `img_call_function_ex` |
| `DICT_MERGE` empty-dest + EX-B `**kwargs` | Done — `img_call_function_ex_kw` |
| `OBK_BUILTIN` / TYPE kwargs | Still `CALL_FILTER` (use ROM Python) |
| Non-empty `DICT_MERGE` (multi-`**`) | Still `CALL_FILTER` |
| `CO_VARARGS` / `CO_VARKEYWORDS` parameters | Still rejected by image tooling |

---

## 2. Immediate builtins-agent work

1. **Replace `% 0` error hacks** with `raise <int-or-object>` where the
   intent is “fatal error”.
2. **Rewrite firmware bodies** that assumed old TO_BOOL limits — `all` /
   `any` / `bool` / `filter(None, …)` can rely on None/container truthiness.
3. **Add kwargs / varargs signatures** where useful as ROM `CODE_OBJECT`s:
   `print(..., sep=, end=)`, `max(..., key=)`, `sorted(..., reverse=)`,
   `zip(*iterables)`, etc. Prefer Python over new `BI_*` keyword tables.
4. **Seed ROM `CODE_OBJECT`s** into the boot-record builtins dict for
   Python-only names (`sum`, `sorted`, `enumerate`, …) while leaving
   `len`/`max`/`range`/`set` as `BI_*` hybrid entries for positional hot paths
   (`image_from_source.build_builtins_dict`).
5. **Wire `pycore_firmware/builtins/*.py` into image build** — compile each
   module, place handles in the builtins dict, and add differential image
   tests that call firmware builtins (not only `BI_*`).
6. **Update per-builtin status** in `builtins.md` as modules move from
   `implemented` → `in ROM`.

---

## 3. Follow-ups that still need bytecode help

| Need | Why |
| --- | --- |
| `CO_VARARGS` / `CO_VARKEYWORDS` on user defs | `def f(*a, **k)` parameters |
| Optional `BI_*` keyword tables | Hardware `print(sep=)` without ROM wrapper |
| Full exception tables / `RERAISE` | Real `TypeError`/`StopIteration`; comprehension option A/B |
| `BI_LEN` tuple-mode RANGE + OBJECT `__bool__` | Complete truthiness / len protocol |
| `GET_ITER`/`FOR_ITER` on OBJECT | Iterator protocol for user types |
| `BI_ORD` / `BI_CHR` | Unblock `ord`/`chr` / `ascii` |
| `LOAD_SUPER_ATTR` + descriptors | `super` / `property` / `classmethod` |
| `COMPARE_OP` string ordering | `sorted`/`min`/`max` on str |
| `FORMAT_*` / `BUILD_STRING` | Richer `str`/`format`/`print` |

---

## 4. Suggested order for the builtins agent

1. Image-seed a small ROM subset (`sum`, `abs`, `bool`, `all`, `any`) beside
   existing `BI_*` entries; add `img_firmware_*` tests.  
2. Sweep error paths to `raise`.  
3. Land kwargs ROM wrappers (`print`/`max`/`sorted`) against live `CALL_KW`.  
4. Finish list-materializing iterators (`enumerate`/`zip`/`map`).  
5. Document remaining blocked builtins against §3 bytecode gaps.

---

## 5. Out of scope (unchanged)

- Host `compile` / full `eval`/`exec` of source  
- Filesystem `open`  
- Async (`aiter`/`anext`)  
- Custom opcodes outside CPython 3.14’s set  
