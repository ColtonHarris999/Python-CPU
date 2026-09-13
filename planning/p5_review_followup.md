# P5 String Accelerator — review follow-up

Findings from the post-merge review of the P5 implementation (String
Accelerator, commits `a9d7c7d`..`6147876` on main). One correctness bug, two
test-coverage gaps, and dead plumbing to remove. This doc is the handoff: each
item lists what, where, why, and how to verify.

Status is tracked inline — **[DONE]**, **[IN PROGRESS]**, or **[TODO]**.

## Status summary (this branch: claude/p5-review-fixes)

- **[DONE, pending CI]** §1 bug fix — order-scan tier-3 escalation + del/pop
  fixture. RTL is unvalidatable host-side; the `gates` job must confirm it.
- **[DONE]** §2 differential coverage — REPLACE, JOIN, isdecimal, isnumeric
  now generated; 12k cases clean host-side.
- **[DONE]** §3 CI seed budget — raised to 8 seeds x 400.
- **[TODO]** §4 dead STRING_HEX plumbing — deliberately deferred to keep this
  PR's RTL change surface to the one correctness fix. Follow-up.
- **[TODO]** §5 allocator-bytes orphan — pre-existing, low priority.

---

## 1. BUG — `del d[k]` / `del obj.attr` with a runtime-built LONG_STR key halts the core

**Severity: correctness. A valid Python program hard-faults.**

`pycore_dict_key_rich_eq` (`pycore_defs.svh`) returns **false** for two
LONG_STR handles at different addresses — the tier-3 payload compare (`SA_CMP`)
is layered on top by the caller via `pycore_str_need_payload_cmp` +
`container_stracc_*`. That escalation (`pycore_core.sv:~1700`,
`container_stracc_issue`) only fires at phase `CP_DICT_CHK_VAL` (dict/set table
probe) and `CP_TAG` (list/tuple CONTAINS).

Two equality sites run in a **different** phase, `CP_DICT_ORDER_SCAN_TAG` (the
insertion-order buffer scan used by deletion), and call the bare function with
no tier-3 escalation:

- `pycore/rtl/pycore_cont_dict.svh:~1225` — `CONT_DELETE_DICT`
- `pycore/rtl/pycore_cont_object.svh:~2519` — `CONT_DELETE_ATTR` (latent:
  attribute names are compile-time interned, so tier 1 always hits today)

For `del d[k]` where `k` is built at runtime and equals an interned key by
content: the table probe matches via tier 3 and deletion begins, then the
order-buffer scan compares with bare tier-1 equality, never matches, walks off
the end of the order buffer, and raises `container_mem_fault_r`
(`PY_TRAP_MEM_FAULT`) — a fatal halt.

**Reproducer** (lint-clean; CPython returns 1):
```python
def managed_entry():
    key = "abcdefgh" + "ijklmnop"
    d = {"abcdefghijklmnop": 42, "other": 7}
    del d[key]
    return len(d)
```

### Preferred fix (verify before implementing)

**Hypothesis to confirm first:** the order buffer stores the *same key handle*
(address-identical) that is in the matched table slot — `CONT_BUILD_MAP` and
the store path insert one handle into both the table and the order buffer. If
so, the order scan does not need `SA_CMP` at all: it should compare each order
entry against the **matched table-slot key handle** (address-equal → tier-1
hit), not against the needle. That is a one-signal change with no second
`SA_CMP` episode.

To confirm: read `CONT_BUILD_MAP` / `CONT_STORE_DICT` in `pycore_cont_dict.svh`
and check that the value written to the order buffer (`pycore_dict_order_val_addr`)
is byte-identical to the value written to the table key slot. If the order
buffer stores the *original insertion* handle and the table stores a *different*
equal handle (possible if an overwrite kept the old table key), the address
assumption breaks and you need the SA_CMP path below.

### Fallback fix (if the address assumption fails)

Add a second tier-3 escalation gated on `CP_DICT_ORDER_SCAN_TAG`. This needs
`container_stracc_done_r` / `container_stracc_eq_r` reset between the table-probe
SA_CMP and the order-scan SA_CMP — they are single-shot per container op today.
Add a phase-qualified clear, or a second done/eq register pair for the order
scan. This is the harder path; prefer the address fix.

### Test that must accompany either fix
- `pycore/programs/img_str_dict_key_runtime_del.py` — `del`/`pop` on a
  runtime-built LONG_STR key equal to an interned one (see reproducer). Wire
  into `pycore-img` in the Makefile next to `pycore-img-str-dict-key-runtime`.

### Verify
`make pycore-img-str-dict-key-runtime-del PYCORE_CACHE_EN=1` passes, and the
existing string/dict suites stay green. **Requires Verilator (CI `gates` job or
a full `make pycore-img`); cannot be validated host-side.**

---

## 2. TEST GAP — differential harness never generates REPLACE, JOIN, isdecimal, isnumeric

`pycore/tools/strgen.py`'s `run_case` op list omits `SA_REPLACE` and `SA_JOIN`
entirely (JOIN is even imported and unused), and the `SA_CLASSIFY` branch never
picks the `DECIMAL` / `NUMERIC` variants (its corpus is ASCII-heavy with no
Unicode-numeric characters). Measured across 40 seeds × 400: 0 runs of each.

These are the two most complex two-pass ops and the two most Unicode-sensitive
classifiers, verified correct only by a handful of directed tests in
`test_strmodel.py`.

**Fix:** add REPLACE and JOIN to the `run_case` op list with CPython goldens
(REPLACE: `hay.replace(old,new)`; JOIN: build a list via `accel.plant_list`,
compare to `sep.join(parts)`), and extend the CLASSIFY corpus with numeric
code points (`"½" "²" "٣" "Ⅻ" "12" "0"`) so DECIMAL/NUMERIC are exercised.
A scratch version of exactly this diff'd 18,000 cases clean, so this is
coverage only — no correctness change expected.

**Verify:** `PYTHONPATH=pycore/tools python3.14 pycore/tools/strgen.py --seed N
--n 400` for several seeds; instrument `StrAccel.exec` to confirm all variants
now fire. Runs host-side, no Verilator.

## 3. TEST GAP — CI differential seed budget is tiny

`pycore/tests/test_strgen.py` runs 2 seeds × 80 cases. The harness does ~24k
cases/second host-side. Raise to a fixed multi-seed set (e.g. seeds 1..8 × 400)
in the `python` job, and optionally a longer sweep behind `workflow_dispatch`
(mirror the `force_hw` shape in `.github/workflows/all-tests.yml`).

## 4. CLEANLINESS — dead STRING_HEX plumbing

`pycore_string_mem.sv` is deleted and `image_from_source.py` no longer emits a
string hex, but the `STRING_HEX` parameter and `+STRING_HEX=` plusarg survive
as no-ops:
- `pycore/rtl/pycore_core.sv:45` — declared, never referenced in the module.
- `pycore/rtl/pycore_system.sv:21,90` and
  `pycore/rtl/pycore_excore_system.sv:28,130` — declared and forwarded.
- `Makefile` — every `PYCORE_IMAGE_RUN`-family recipe passes
  `+STRING_HEX=$(BUILD_DIR)/.../string_mem.hex` (a file no longer generated);
  `PYCORE_STRING_HEX`/`RUN_STRING_HEX` vars; the `-GSTRING_HEX=\"\"` build flag.

Inert (the sim ignores an unset plusarg), but misleading. Remove the parameter,
the port forwards, and the Makefile plusargs together. **Touches RTL, so verify
with a full build** — the `preprocess.py` path (`pycore-preprocess`) still uses
`--string-hex` and is a *separate legacy tool*; do not remove that one.

## 5. MINOR — pre-existing, not P5

`pycore-img-allocator-bytes` is defined but unreachable from any suite
(predates P5, from #45). `pycore-img-two-core` is an alias also unreached. Wire
into a suite or delete. Low priority.

---

## What is already verified good (do not re-litigate)

- All nine Latin-1 classify masks exact vs CPython across all 256 code points;
  `toupper`/`tolower`/`casefold` exact including `ß`→`SS`, `µ`/`ÿ` specials.
- Canonical SHORT/LONG rule enforced at a single choke point (`setup_copy`).
- Three-tier equality correct at all 14 non-order-scan sites.
- OOM checked before the heap pointer moves.
- Memory map moved as planned; firmware string builtins retired; new fixtures
  reachable from `pycore-img`; CI green on main.
