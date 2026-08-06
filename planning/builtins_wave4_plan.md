# Builtins wave 4 — what comes next

**Audience:** next agent (firmware, bytecode, or excore)  
**Prerequisite:** wave 3 ROM seed landed (`planning/builtins_rom_wave3_plan.md`)  
**Current ROM set:** 21 `CODE_OBJECT` builtins in `ROM_FIRMWARE_BUILTINS`

Wave 3 finished the easy pure-Python seed + `sorted(reverse=)` /
`sum(start=)`. Remaining work needs **new hardware / excore / bytecode**,
not just more `.py` stubs.

---

## 1. Priority A — `print` console (testing win)

**Why first:** full-program tests can assert stdout instead of packing
everything into one INT return.

| Layer | Work |
| --- | --- |
| MMIO | Add write-only console sink (e.g. `CONSOLE_TX` byte / ring) on excore MMIO map; TB captures to a log file |
| Excore | Handle `PY_TRAP_BUILTIN_CALL` for `BI_PRINT`: stringify INT/BOOL/None/SHORT_STR, write bytes, `COMPLETED` + push `None` |
| Firmware | Optional ROM `CODE_OBJECT` wrapper with `sep=` / `end=` (CALL_KW) that calls into native print or builds one string then traps |
| Tests | `img_print_basic.py` + golden `.stdout`; extend `run_image_test` / Makefile to diff captured output |

**Out of scope for A:** full `str`/`repr` for containers; `file=` streams.

Plan detail can live in `pycore_firmware/builtins/print.md` once started.

---

## 2. Priority B — attribute protocol primitives (unblocks many builtins)

### 2.0 Problem (why wave-3 skipped these)

Hardware `LOAD_ATTR` already **uses** the instance dict (header field0) to
resolve ordinary names like `obj.x`. That is not the same as Python
evaluating `obj.__dict__`.

Firmware bodies need the **handle itself**:

```python
d = obj.__dict__          # LOAD_ATTR name="__dict__"
cls = obj.__class__       # LOAD_ATTR name="__class__"
base = cls.__base__       # LOAD_ATTR name="__base__"
```

Today those names are probed as ordinary string keys in `__dict__` / MRO.
They are almost never present → `PY_TRAP_ATTR_ERROR`. So `hasattr` /
`getattr` / `setattr` / `delattr` / `isinstance` / `issubclass` cannot be
ROM-seeded until `CONT_LOAD_ATTR` special-cases them.

| Phrase in docs | Meaning |
| --- | --- |
| “probe `__dict__`” | use field0 as storage for `obj.foo` (already works) |
| “`LOAD_ATTR __dict__`” | return field0 as a Python value (missing) |

### 2.1 Goal

Extend `CONT_LOAD_ATTR` in `pycore/rtl/pycore_cont_object.svh` so these
names return header fields **before** any dict probe:

| Name | Receiver | Return |
| --- | --- | --- |
| `__dict__` | `OBK_INSTANCE` | field0 `MUT_DICT` handle (tag+addr) |
| `__dict__` | `OBK_TYPE` | field0 `tp_dict` handle (same shape; useful for `vars`/`dir` later) |
| `__class__` | `OBK_INSTANCE` | `PY_TAG_OBJECT` handle to `ob_type` (`OBK_TYPE`) |
| `__class__` | `OBK_TYPE` | the type itself (identity), **or** ATTR_ERROR — pick one and test it; prefer **self** for simplicity |
| `__base__` | `OBK_TYPE` | field1 `tp_base`: `OBJECT` handle if non-zero, else `None` |
| `__base__` | `OBK_INSTANCE` | fall through to normal probe (miss → ATTR_ERROR) |

**Not in v1:** descriptors, `__getattribute__`, module objects, changing
`__class__` / replacing `__dict__` via `STORE_ATTR`.

### 2.2 Hook point (RTL)

Existing phases (do not redesign the arm):

1. `CP_INIT` → `CP_NAME_VAL` → `CP_NAME_TAG` — load `co_names[namei]` into
   `container_val_r` / `container_tag_r`
2. `CP_ATTR_HEAD` — read `ob_head`; branch INSTANCE vs TYPE
3. `CP_ATTR_IDICT` / MRO probe… — **today always probes**

**Insert the special-case in `CP_ATTR_HEAD`** (or a new one-cycle phase
right after it) once `attr_ob_kind` is known and the name is already
latched:

```text
CP_ATTR_HEAD:
  kind = INSTANCE | TYPE | other→TYPE_TRAP
  if name is special for this kind:
      issue the field/ob_type read (or writeback None)
      → existing data-attr writeback path (method_flag ignored /
        treat as non-callable data: replace TOS only)
  else:
      existing CP_ATTR_IDICT / CP_ATTR_TYPE path
```

Name match: all three strings are ≤15 bytes → image tooling emits
`SHORT_STR`. Compare `container_tag_r == SHORT_STR` and
`container_val_r` against the three packed literals (reuse
`pycore_make_short_str` / the same packing helpers used elsewhere).
If a name somehow arrives as `LONG_STR`, fall through to normal probe
(v1); do not add a heap string walk just for specials.

`method_flag` (`cur_arg_r[0]`): specials are data attributes. Writeback
must **replace TOS with the value only** (no `[func, self]` / no
`BOUND_METHOD` alloc), regardless of method_flag. Mirror how non-callable
dict hits already write back.

### 2.3 Per-name micro-sequences

**`__dict__` (INSTANCE or TYPE)**  
Field0 is already the next read on the INSTANCE path (`CP_ATTR_IDICT`).
On special hit: read field0 val+tag, require `MUT_COLLEC` dict (same check
as today), push that handle, done. Do **not** enter `CP_HDR` / probe.

**`__class__` (INSTANCE)**  
`ob_type` is already extracted in `CP_ATTR_HEAD` as `attr_ob_type`. If
non-zero, push `{PY_TAG_OBJECT, attr_ob_type}`; if zero, `None` or
TYPE_TRAP (prefer `None` only if boot instances can lack a type — today
seeded instances have types, so TYPE_TRAP on 0 is fine).

**`__base__` (TYPE)**  
Read field1 val+tag. Zero / null → push `None` (so
`issubclass` loops terminate). Non-zero → push `OBJECT` handle.

### 2.4 STORE_ATTR / DELETE_ATTR (v1 policy)

| Op | Name | Policy |
| --- | --- | --- |
| `STORE_ATTR` | `__dict__` / `__class__` / `__base__` | `PY_TRAP_TYPE` (no mutation of headers via Python) |
| `DELETE_ATTR` | same | `PY_TRAP_TYPE` or ATTR_ERROR — prefer **TYPE** |

Ordinary `STORE_ATTR` / `DELETE_ATTR` on user keys unchanged (still operate
on instance field0 dict only).

Optional later: `obj.__dict__[k] = v` via subscript after LOAD special
already covers firmware `setattr` without STORE_ATTR-by-string.

### 2.5 Implementation steps

1. **RTL helpers** — add `pycore_is_attr_special_*` (or three constant
   SHORT_STR compares) next to other string helpers in `pycore_defs.svh`.
2. **`CONT_LOAD_ATTR`** — special branch in/after `CP_ATTR_HEAD`; reuse
   existing writeback phases for data attrs; keep MRO path untouched for
   non-specials.
3. **`CONT_STORE_ATTR` / `CONT_DELETE_ATTR`** — reject the three names
   early (after name load + kind check).
4. **Docs** — update `object_model.md` LOAD_ATTR section (remove “Not yet
   special-cased”); note STORE/DELETE policy.
5. **Image tests** (single-core first):

   | Program | Intent |
   | --- | --- |
   | `img_attr_dunder_dict.py` | `SEED_INSTANCE`; `o.__dict__` is dict; `o.__dict__["x"]` after `o.x = …` |
   | `img_attr_dunder_class.py` | instance `__class__ is T` for `SEED_TYPE`/`SEED_INSTANCE` |
   | `img_attr_dunder_base.py` | `Child.__base__ is Base`; top `__base__ is None` |
   | `img_attr_dunder_store_trap.py` | `o.__dict__ = …` → TYPE trap |

6. **Firmware ROM seed (after RTL green)** — add to
   `ROM_FIRMWARE_BUILTINS`: `hasattr`, `getattr`, `setattr`, `delattr`,
   `isinstance`, `issubclass`. Image programs:

   - `img_firmware_attr_helpers.py` — getattr/hasattr/setattr round-trip
   - `img_firmware_isinstance.py` — single-class walk via `__class__`/`__base__`

7. **Makefile** — wire the new `pycore-img-*` targets into the image-test
   lists (same pattern as wave 3).

### 2.6 Acceptance

- [ ] `o.__dict__` returns a live dict; subscript/contains work
- [ ] `o.__class__` is the seeded `OBK_TYPE`
- [ ] `T.__base__` walks; terminates at `None`
- [ ] Normal `o.x` / MRO method load **unchanged** (existing attr tests still green)
- [ ] STORE/DELETE of the three names TYPE-traps
- [ ] Firmware attr + isinstance helpers **in ROM** with green image tests

### 2.7 Explicitly out of scope for B

- Runtime-string `LOAD_ATTR` (CPython still uses `co_names`; firmware
  `getattr(obj, name)` uses `__dict__[name]` after the special load)
- Tuple-of-types `isinstance` / `issubclass`
- `type(x)` builtin / `BI_TYPE` (nice-to-have after `__class__`)
- Full CPython descriptor / `__getattribute__` / module `__dict__`
- Making `__dict__` a mappingproxy

### 2.8 Suggested split

| Step | Owner |
| --- | --- |
| 2.5.1–2.5.5 RTL + attr image tests | pycore / bytecode agent |
| 2.5.6–2.5.7 ROM seed + firmware tests | firmware builtins agent |

Also useful after B lands (not blockers for the specials themselves):

- `BI_TYPE` or CALL on `type` one-arg → tag/ob_type expose
- Tuple-of-types `isinstance` once single-class works

---

## 3. Priority C — `BI_ORD` / `BI_CHR` (native, not custom opcodes)

| Id | Behavior |
| --- | --- |
| `BI_ORD` | One-char STR → INT code point (reuse STR FOR_ITER UTF-8 decode) |
| `BI_CHR` | INT → one-char SHORT_STR (UTF-8 encode, range checks) |

Seed `ord` / `chr` in builtins dict; then firmware `ascii` becomes feasible.
See existing `ord.md` / `chr.md`.

---

## 4. Priority D — bytecode / CALL follow-ups

| Item | Unlocks |
| --- | --- |
| `CO_VARARGS` / `CO_VARKEYWORDS` on defs | `zip(*args)`, `map(f, *iterables)`, `print(*args)` as Python |
| Exception tables / real exception objects | Replace fatal `raise` / TYPE traps with `TypeError`/`StopIteration` |
| `COMPARE_OP` string ordering | `sorted`/`min`/`max` on str |
| `GET_ITER` / `FOR_ITER` on OBJECT | User `__iter__` / `__next__` |
| `FORMAT_*` / `BUILD_STRING` | Richer `str`/`format`/`print` |
| `LOAD_SUPER_ATTR` + descriptors | `super`, `property`, `classmethod` |
| `TO_BOOL` OBJECT `__bool__`/`__len__` | Truthiness protocol completion |

---

## 5. Priority E — more ROM seeds (after B/C)

Once primitives land, seed without new invention:

- `hasattr`, `getattr`, `setattr`, `delattr`, `isinstance`, `issubclass`
- `ord`, `chr`, then `ascii`
- Optional ROM `max`/`min` kwargs wrappers **without** removing `BI_MAX`
  (document shadowing policy)

Still hybrid: keep `BI_LEN` / `BI_RANGE` / `BI_SET` / `BI_MAX` positional.

---

## 6. Explicitly deferred

- Host `compile` / string `eval`/`exec` (`compile.md`)
- Filesystem `open` / `input`
- Async (`aiter`/`anext`)
- `frozenset`, `memoryview`, `slice` objects, buffer protocol
- `locals` / `globals` / `id` / `hash` frame or probe exposure
- Custom non-CPython opcodes

---

## 7. Suggested owner split

| Track | Owner | First deliverable |
| --- | --- | --- |
| A print console | excore + TB | `BI_PRINT` writes bytes; one stdout golden test |
| B attr specials | pycore RTL (LOAD_ATTR) | §2 plan: specials in `CONT_LOAD_ATTR` + image tests, then ROM seed |
| C ORD/CHR | pycore CALL FSM | `BI_ORD` / `BI_CHR` + image tests |
| D bytecode | bytecode agent | `CO_VARARGS` or str `COMPARE_OP` |
| E ROM seed | firmware agent | seed attr + ord/chr after B/C |

---

## 8. Success metric for wave 4

At least one of:

1. A program with `print(...)` checked via captured stdout in CI, **or**
2. `hasattr`/`getattr`/`isinstance` in ROM with green image tests, **or**
3. `ord`/`chr` native + ROM/tests.

Do not open a “seed everything remaining” PR without one of those
primitives.
