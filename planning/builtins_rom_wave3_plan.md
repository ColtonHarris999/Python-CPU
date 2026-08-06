# Builtins ROM wave 3 — next implementations

**Audience:** firmware builtins agent  
**Branch:** `builtins` (merged from `main` as of wave-2 ROM seed)  
**Supersedes / extends:** `planning/builtins_next_steps_plan.md` §4.5  
**Do not reinvent:** LEGB-B, `BI_*` fast paths, ROM seed plumbing
(`ROM_FIRMWARE_BUILTINS` / `seed_rom_firmware_builtins`) — already shipped.

Related:

- Inventory: `pycore_firmware/builtins/builtins.md`
- Seed registry: `pycore/tools/image_from_source.py` → `ROM_FIRMWARE_BUILTINS`
- Coverage today: `img_firmware_rom_subset`, `img_firmware_iterators`
- Unit seed tests: `pycore/tests/test_rom_firmware_seed.py`
- CALL kwargs: `planning/call_kw_support_plan.md` (**done** for `CODE_OBJECT`)

---

## 1. Current baseline (do not redo)

| In ROM (`CODE_OBJECT`) | Native `BI_*` (keep positional hot path) |
| --- | --- |
| `abs`, `all`, `any`, `bool`, `sum` | `len` (`BI_LEN` + `__len__` miss) |
| `enumerate`, `map`, `zip` | `max` (`BI_MAX` 2-arg), `range`, `set`, `print` trap |

Phase 1–2 of `builtins_next_steps_plan.md` are **done**. Wave 3 grows the
ROM set and lands the first kwargs-aware Python wrappers.

---

## 2. Goals for wave 3

1. Seed more **already-implemented** firmware bodies into
   `ROM_FIRMWARE_BUILTINS` with differential image tests.
2. Fix / finish bodies **unblocked by recent bytecode** (`tuple` via
   `LIST_TO_TUPLE`, kwargs via `CALL_KW`).
3. Keep **hybrid** policy: do not replace `BI_LEN` / `BI_RANGE` / `BI_SET` /
   `BI_MAX` positional paths with slower Python.
4. Leave I/O (`print` console MMIO), `ord`/`chr`, descriptors, and
   `compile`/`eval`/`exec` for later waves (tracked in §6).

---

## 3. Wave 3A — ROM seed of ready pure-Python (positional)

Add these to `ROM_FIRMWARE_BUILTINS` and mark **in ROM** in `builtins.md`.
Each already has a `.py` body that validates under `SUPPORTED_OPS`.

| Builtin | Source | Notes / test idea |
| --- | --- | --- |
| `divmod` | `divmod.py` | `return divmod(7, 3)` → `(2, 1)` unpack sum |
| `pow` | `pow.py` | `pow(2, 10)` and `pow(2, 10, 100)` |
| `round` | `round.py` | Numeric only; document half-away-from-zero |
| `bin` / `hex` / `oct` | respective | Concat string loops; compare short-str equality or lengths |
| `reversed` | `reversed.py` | List materialize; needs excore for grow |
| `filter` | `filter.py` | `filter(None, …)` + small predicate `CODE_OBJECT` |
| `sorted` | `sorted.py` | Numeric list only until str `COMPARE_OP` |
| `min` | `min.py` | Iterable or `(a, b)` ROM form — **do not** remove `BI_MAX` |
| `list` | `list.py` | From tuple/range; excore LIST_EXTEND |
| `dict` | `dict.py` | From list of pairs |
| `tuple` | `tuple.py` | Already uses `(*out,)` / LIST_TO_TUPLE — seed + test |
| `hasattr` / `getattr` / `setattr` / `delattr` | attr helpers | Image-seeded instance (`SEED_INSTANCE`) |
| `isinstance` / `issubclass` | type walk | Single-class `classinfo` only |

### 3A acceptance

- Registry length grows; `test_rom_firmware_seed` still passes.
- New image program(s), e.g. `img_firmware_rom_wave3a.py`, exercise a
  representative subset (not necessarily every name in one file).
- Two-core where LIST grow / SET_UPDATE is required (`reversed`,
  `sorted`, `list`, `filter`, `tuple` materialize).
- `builtins.md` status → **in ROM** for each seeded name.

### 3A implementation checklist

1. Confirm each candidate `validate_code_tree` (extend
   `test_rom_firmware_seed.test_registry_sources_validate`).
2. Append `(dict_key, stem, func_name)` rows to `ROM_FIRMWARE_BUILTINS`.
3. Refresh stale docstrings (`sorted.py` still says “CALL_KW deferred”;
   `print.py` similarly stale).
4. Add Makefile / `all-tests` wiring for new `img_firmware_*` targets
   matching existing `img_firmware_rom_subset` pattern.
5. Prefer small expected **INT** returns (current test harness); do not
   block on stdout capture.

**Batching suggestion:** ship 3A in two PRs if CI time hurts —

- **3A.1:** `divmod`, `pow`, `round`, `bin`, `hex`, `oct`, `tuple`
- **3A.2:** `reversed`, `filter`, `sorted`, `min`, `list`, `dict`, attr +
  `isinstance`/`issubclass`

---

## 4. Wave 3B — kwargs / richer signatures (`CALL_KW` ready)

Hardware binds kwargs on **`CODE_OBJECT`** only. Native `BI_*` stays
positional (`CALL_FILTER` on kwargs).

| Builtin | Change | Keep native? |
| --- | --- | --- |
| `sorted` | Add `reverse=False` (and optionally `key=None` no-op / trap if key not None until CALL of key works well) | N/A (Python-only) |
| `max` / `min` | ROM wrappers: iterable form + optional `default=`; `key=` if straightforward | Yes — leave `BI_MAX` for bare `max(a, b)` |
| `sum` | Allow `start=` keyword (already has default positional) | Already ROM |
| `enumerate` | `start=` already positional default — add kw form if cheap | Already ROM |
| `print` | **Not in 3B** — needs console (§6). May sketch ROM wrapper signature only. | `BI_PRINT` trap remains |

### 3B acceptance

- Image tests call e.g. `sorted([3, 1, 2], reverse=True)` via `CALL_KW`.
- Shadowing: `max(1, 2)` still hits `BI_MAX` if globals/builtins still
  expose the builtin handle for the name `max`.  
  **Important design choice (pick one and document in `builtins.md`):**

  | Option | Behavior |
  | --- | --- |
  | **B1 (recommended)** | Keep builtins dict `max` → `BI_MAX`. Add ROM helpers under different names only if needed, *or* document that kwargs `max` is unsupported until a ROM wrapper **replaces** the dict entry. |
  | **B2** | Replace builtins dict `max` with ROM `CODE_OBJECT` that fast-paths 2-arg compare in Python and supports iterable/`default=`. Loses HW `BI_MAX` unless CALL FSM still special-cases. |

  Prefer **B1** for wave 3: implement kwargs on `sorted` / `sum` first;
  defer replacing `max`/`min` dict entries.

### 3B implementation checklist

1. Rewrite `sorted(iterable, reverse=False)` using CALL_KW-valid defaults.
2. Image test `img_firmware_sorted_kw.py`.
3. Optionally `sum(xs, start=10)` kw test.
4. Update `builtins.md` gap table row “Kwargs ROM wrappers”.

---

## 5. Wave 3C — quality / protocol (small, high value)

| Item | Work |
| --- | --- |
| `tuple` status | Move `tuple` from in progress → implemented/in ROM after 3A seed |
| `len` miss path | Ensure ROM `len.py` (`obj.__len__()`) is **not** seeded over `BI_LEN`; keep as documentation / optional secondary only |
| `% 0` stubs | Convert remaining **activated** modules to `raise`; leave inactive blocked stubs |
| `filter` / `map` | Document list-materialization deviation; no YIELD in this wave |
| Attr helpers | Document instance-dict-only limitation; no MRO claim |

---

## 6. Explicitly deferred (wave 4+)

| Work | Why deferred |
| --- | --- |
| `print` + console MMIO + TB stdout capture | Needs excore handler + device; huge testing win — separate plan |
| `BI_ORD` / `BI_CHR` → `ord`/`chr`/`ascii` | Bytecode/native helper gap |
| `super` / `property` / `classmethod` | `LOAD_SUPER_ATTR` + descriptors |
| `str`/`repr`/`int`/`float` tag dispatch | Need tag probe or speculative paths |
| `zip(*args)` / `map(f, *iterables)` | `CO_VARARGS` still rejected by image tooling |
| `compile` / `eval` / `exec` / `open` | See per-builtin `.md` plans |
| Async, frozenset, memoryview, slice objects | Layout / opcode gaps |

---

## 7. Suggested order (one agent, sequential)

1. **3A.1** numeric/string helpers + `tuple` seed + tests  
2. **3A.2** container/iterator helpers + attr/isinstance seed + tests  
3. **3B** `sorted(..., reverse=)` (+ optional `sum` kw)  
4. Open follow-up issue/plan for **print console** (testing) and **ORD/CHR**

Do not start print MMIO inside the same PR as 3A seed spam.

---

## 8. Files expected to change

| Area | Files |
| --- | --- |
| Registry | `pycore/tools/image_from_source.py` (`ROM_FIRMWARE_BUILTINS`) |
| Firmware bodies | `pycore_firmware/builtins/{sorted,tuple,min,…}.py` as needed |
| Inventory | `pycore_firmware/builtins/builtins.md` |
| Tests | `pycore/tests/test_rom_firmware_seed.py`, new `pycore/programs/img_firmware_*.py`, `Makefile` |
| This plan | mark § steps done as PRs land; keep `builtins_next_steps_plan.md` §4.5 pointing here |

---

## 9. Out of scope

- Custom non-CPython opcodes  
- Replacing working `BI_LEN` / `BI_RANGE` / `BI_SET` / `BI_MAX` fast paths  
- Full CPython exception objects / handlers  
- Host compiler on the hart  
