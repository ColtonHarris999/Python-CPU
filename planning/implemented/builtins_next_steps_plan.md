# Builtins agent — next steps (post CALL_KW)

**Audience:** agent finishing / integrating `pycore_firmware/builtins/`  
**Completed by bytecode agent:** see §1  
**Unblock:** `CALL_KW` / `CALL_FUNCTION_EX` / empty-dest `DICT_MERGE` are live for
`CODE_OBJECT` callees — kwargs / varargs ROM signatures are now allowed.

Related:

- CALL_KW plan (implemented): `planning/implemented/call_kw_support_plan.md`
- Prior bytecode plan: `planning/implemented/builtins_bytecode_support_plan.md`
- Inventory: `pycore_firmware/builtins/builtins.md`
- Opcode matrix: `pycore/docs/bytecode_support.md`
- **Active implementation plan:** [`planning/implemented/for_loop_full_support_plan.md`](for_loop_full_support_plan.md)
  (GET_ITER/FOR_ITER on OBJECT, StopIteration-only exception tables, list/dict comps)
- **Prior ROM firmware work:** **Done** — waves 1–4 (`ROM_FIRMWARE_BUILTINS`, print console, attr specials)

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
| `CO_VARARGS` on defs | **Done** — binder packs `*args`; `img_varargs_*` / ROM `print` |
| `CO_VARKEYWORDS` (`**kwargs` param) | **Done** — binder packs leftovers; `img_varkw_*` / posonly parity (`planning/implemented/co_varkeywords_call_parity.md`) |

---

## 2. Immediate builtins-agent work

1. **Replace `% 0` error hacks** with `raise <int-or-object>` where the
   intent is “fatal error”.
   **Done (priority set):** `range`, `iter`, `next`, `int`, `float`. Remaining
   blocked stubs still use `% 0` until those modules become active.
2. **Rewrite firmware bodies** that assumed old TO_BOOL limits — `all` /
   `any` / `bool` / `filter(None, …)` can rely on None/container truthiness.
   *(§4.1: refreshed `all.py` / `any.py` TO_BOOL comments.)*
3. **Add kwargs / varargs signatures** where useful as ROM `CODE_OBJECT`s:
   `print(..., sep=, end=)`, `max(..., key=)`, `sorted(..., reverse=)`,
   `zip(*iterables)`, etc. Prefer Python over new `BI_*` keyword tables.
4. **Seed ROM `CODE_OBJECT`s** into the boot-record builtins dict for
   Python-only names while leaving `len`/`max`/`range`/`set` as `BI_*`
   hybrid entries for positional hot paths
   (`image_from_source.build_builtins_dict`).
   **Done:** `ROM_FIRMWARE_BUILTINS` includes §4.1 five + `enumerate`/`map`/`zip`.
5. **Wire `pycore_firmware/builtins/*.py` into image build** — compile each
   module, place handles in the builtins dict, and add differential image
   tests that call firmware builtins (not only `BI_*`).
   **Done:** `img_firmware_rom_subset.py`, `img_firmware_iterators.py`.
6. **Update per-builtin status** in `builtins.md` as modules move from
   `implemented` → `in ROM`.
   **Done** for all 28 `ROM_FIRMWARE_BUILTINS` names (waves 1–4).

---

## 3. Follow-ups that still need bytecode help

| Need | Why |
| --- | --- |
| `CO_VARKEYWORDS` on user defs | **Done** — `def f(**k)` packing + posonly; see `planning/implemented/co_varkeywords_call_parity.md` |
| Optional `BI_*` keyword tables | Hardware kwargs without ROM wrapper |
| Full exception tables / `RERAISE` | **Active:** [`for_loop_full_support_plan.md`](for_loop_full_support_plan.md) Track B (StopIteration only); retires comprehension Policy C when Track C lands |
| `BI_LEN` tuple-mode RANGE + OBJECT `__bool__` | Complete truthiness / len protocol |
| `GET_ITER`/`FOR_ITER` on OBJECT | **Active:** [`for_loop_full_support_plan.md`](for_loop_full_support_plan.md) Track A |
| `BI_ORD` / `BI_CHR` | Unblock `ord`/`chr` / `ascii` |
| `LOAD_SUPER_ATTR` + descriptors | `super` / `property` / `classmethod` |
| `COMPARE_OP` string ordering | `sorted`/`min`/`max` on str |
| `FORMAT_*` / `BUILD_STRING` | Richer `str`/`format`/`print` |

---

## 4. Suggested order for the builtins agent

### 4.1 First ROM subset — **done**

| Item | Status |
| --- | --- |
| `ROM_FIRMWARE_BUILTINS` registry (`sum`, `abs`, `bool`, `all`, `any`) | Done |
| `seed_firmware_function()` / `seed_rom_firmware_builtins()` | Done |
| `build_builtins_dict(serializer)` integration | Done |
| `img_firmware_rom_subset.py` differential test | Done |
| `builtins.md` → **in ROM** for all five | Done |

### 4.2–4.4 — Phase 2 — **done**

| Step | Item | Status |
| --- | --- | --- |
| **4.2** | Sweep `% 0` → `raise` (priority: `range`, `iter`, `next`, `int`, `float`) | Done |
| **4.3** | ROM seed `enumerate`, `zip`, `map` + `img_firmware_iterators` (two-core) | Done |
| **4.4** | Document blocked builtins vs §3 gaps in `builtins.md` | Done |

### 4.5 — **done** → see `planning/implemented/builtins_rom_wave3_plan.md`

Wave 3 shipped 13 additional ROM builtins + kwargs tests.

### 4.6 — **done** (wave 4 §2 attr specials)

`LOAD_ATTR` specials for `__dict__` / `__class__` / `__base__`; ROM seed of
`hasattr` / `getattr` / `setattr` / `delattr` / `isinstance` / `issubclass`.

### 4.7 — **done** (wave 4 §1 print console)

ROM `print(*args, sep=, end=)` → `_bi_print` / `BI_PRINT` → `CONSOLE_TX`;
stdout goldens via `PYCORE_IMAGE_RUN_TWOCORE_STDOUT`.  
**Next:** `planning/builtins_wave4_plan.md` Priority C (`BI_ORD`/`BI_CHR`).

---

## 5. Out of scope (unchanged)

- Host `compile` / full `eval`/`exec` of source  
- Filesystem `open`  
- Async (`aiter`/`anext`)  
- Custom opcodes outside CPython 3.14’s set  
