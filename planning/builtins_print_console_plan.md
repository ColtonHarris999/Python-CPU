# `print()` console — full implementation plan

**Status:** proposal (for review)  
**Audience:** excore + TB + firmware agents  
**Parent:** `planning/builtins_wave4_plan.md` §1 (Priority A)  
**Unblocks:** stdout-based image tests; later kwargs `print` / richer stringify

Related:

- Firmware stub: `pycore_firmware/builtins/print.py`
- Builtin id: `PY_BI_PRINT = 6` (`pycore/rtl/pycore_defs.svh`, `encoding.py`)
- Trap: `PY_TRAP_BUILTIN_CALL = 16` (recoverable)
- CALL marshal: `pycore/rtl/pycore_call_fsm.svh` (phase 13 → trap)
- Excore FW: `excore/fw/list_grow.s`
- MMIO map: `excore/docs/mmio_map.md`
- Handler checklist: `excore/docs/adding_a_trap_handler.md`

---

## 1. Goal / non-goals

### Goal

Make `print(...)` work on the **two-core** top so a program can emit
bytes to a console sink and CI can golden-diff that output, while still
returning a normal INT from `managed_entry()` for the existing return check.

### MVP acceptance

```python
def managed_entry():
    print(1)
    print(True, None)
    print("hi")
    return 0
```

Sim stdout (captured from MMIO writes):

```text
1
True None
hi
```

(`sep=" "` / `end="\n"` hardcoded in the native handler for MVP.)

### Non-goals (MVP)

- `file=` / streams / `open`
- Container / OBJECT `__str__` / `__repr__`
- LONG_STR (optional stretch; see §8)
- Native `sep=` / `end=` on `OBK_BUILTIN` (CALL_KW → `CALL_FILTER` today)
- `*args` / `CO_VARARGS` (bytecode track)
- Single-core / `EXCORE_EN=0` (print stays excore-only)

---

## 2. What already exists

| Piece | State |
| --- | --- |
| `"print"` in boot builtins dict | Seeded as `OBK_BUILTIN` / `BI_PRINT=6` (`image_from_source.py`) |
| Positional `CALL` → trap 16 | Marshaled when `EXCORE_EN=1` (`pycore_call_fsm.svh` ~434–457) |
| Mailbox / COMPLETED protocol | Live for LIST/DICT/SET traps |
| Firmware `str` / `repr` (Python) | INT/BOOL/None decimal / literals — usable later for ROM wrapper |
| Console MMIO | **Missing** |
| Excore dispatch for trap 16 | **Missing** (`list_grow.s` → `fatal_illegal`) |
| TB stdout capture | **Missing** |
| Image programs calling `print` | **None** |
| `print.md` deep plan | This doc (planning/); optional short pointer under firmware |

### Trap / mailbox contract (current hardware — do not invent a new opcode)

On `CALL` of free `print` with positional args:

| Field | Value |
| --- | --- |
| `trap_code` | `16` (`PY_TRAP_BUILTIN_CALL`) |
| `MB_INSTR` oparg | `argc` (CALL oparg) |
| `E0` | Builtin `OBJECT` handle |
| `E1` | `bound_self` (NULL for free function) |
| `E2` | arg0 if `argc ≥ 1` |
| `E3` | arg1 if `argc ≥ 2` |
| `entry_count` | 2 / 3 / 4 for argc 0 / 1 / ≥2 |

**Hard limits baked into today’s marshal:**

1. At most **two argument values** land in the mailbox (`MAX_TRAP_ENTRIES=4` = handle + self + 2 args). `argc > 2` still traps, but args beyond the first two are **not** copied into `E*`.
2. `builtin_id` is **not** a mailbox field — firmware must slot-read `E0` → object field0 (`INT` id).
3. Stack is **not** popped before the trap — COMPLETED must pop `2 + argc` (callable + NULL + args) and push `None`.
4. `RES_POP_COUNT` is **3 bits** → max pop **7** → native `argc ≤ 5` even if mailbox were widened later.
5. `CALL_KW` / kwargs on `OBK_BUILTIN` → **`CALL_FILTER`** (not trap 16).

---

## 3. Recommended architecture

### Hybrid: native MVP, ROM wrapper later

```text
MVP (ship first)
  builtins["print"] = OBK_BUILTIN(BI_PRINT)
       │
       ▼  positional CALL, EXCORE_EN=1
  PY_TRAP_BUILTIN_CALL (16)
       │
       ▼
  excore do_bi_print
       ├─ stringify ≤2 args (INT/BOOL/None/SHORT_STR)
       ├─ write bytes to CONSOLE_TX (sep/end hardcoded)
       └─ COMPLETED → pop 2+argc, push None

Phase 2 (kwargs / more args)
  builtins["print"] = ROM CODE_OBJECT
       │  sep=/end= via CALL_KW; fixed positionals (no *args yet)
       ▼
  build one SHORT_STR (or LONG_STR later)
       │
       ▼
  private native sink  (still OBK_BUILTIN BI_PRINT, or rename _print)
       │
       ▼
  same CONSOLE_TX path (typically argc=1)
```

**Why not pure-ROM for MVP?** Python cannot emit host-visible bytes without
an MMIO/trap sink. Some native path is required either way.

**Why not kwargs on native BI first?** Would need a CALL_KW keyword table
for `OBK_BUILTIN` (call_kw plan v2). Wave-4 / call_kw v1 already chose
“force Python for kwargs.”

---

## 4. MMIO: `CONSOLE_TX`

### Proposal

| Item | Choice |
| --- | --- |
| Name | `CONSOLE_TX` |
| Offset | `0xF0` (free hole after slot-port data in the 8-bit decode window) |
| Access | Write-only, 32-bit store; **low byte** is the character |
| Behavior (RTL) | Accept write; no readable status required for MVP |
| Capture | TB / Verilator `$fwrite` on write (sim-only); silicon can discard |

Document in `excore/docs/mmio_map.md`. Implement decode in
`excore/rtl/excore_mmio.sv`.

### Alternatives considered

| Option | Why not for MVP |
| --- | --- |
| Word + length burst | More RTL; little gain for ≤2 SHORT_STRs |
| Scratch ring in dmem | Heavier firmware + TB poll |
| Put capture only in TB spy without MMIO | Firmware still needs *some* store target; a real WO reg is cleaner |

---

## 5. Excore handler algorithm

File: `excore/fw/list_grow.s`

### 5.1 Dispatch

```text
wait_trap:
  ...
  beq trap_code, TRAP_BUILTIN_CALL(=16), do_builtin_call
  j fatal_illegal

do_builtin_call:
  # slot-read E0 → OBK_BUILTIN → field0 INT id
  if id == BI_PRINT: j do_bi_print
  # BYTEARRAY / FROM_BYTES / TO_BYTES share trap 16 — leave fatal for now
  j fatal_illegal
```

### 5.2 `do_bi_print`

1. Read `argc` from `MB_INSTR` oparg.
2. If `argc > 2` → `FATAL(TYPE)` for MVP (mailbox truncated; do not silently print partial args). Document; Phase 2 ROM wrapper avoids this for multi-arg + kwargs.
3. For `i` in `0 .. argc-1`:
   - Load arg from `E2` / `E3`.
   - Stringify into a small scratch buffer (see §5.3).
   - If `i > 0`, write `0x20` (`' '`) to `CONSOLE_TX`.
   - Write buffer bytes to `CONSOLE_TX`.
4. Write `0x0A` (`'\n'`) to `CONSOLE_TX`.
5. COMPLETED:

```text
RES_CODE       = 0 (COMPLETED)
RES_POP_COUNT  = 2 + argc
RES_PUSH_COUNT = 1
RES_ENTRY[0]   = None   # TAG_CONTROL, ctl_id = PY_CTL_NONE (1)
RES_HEAP_PTR   = MB_HEAP_PTR (unchanged)
RES_GO         = 1
```

Mirror the COMPLETED push style used by `DICT_MERGE` / other handlers in
`list_grow.s`.

### 5.3 Stringify (excore asm, MVP)

| Tag | Output |
| --- | --- |
| `INT` | Signed decimal ASCII (reuse digit-loop idea from firmware `str.py`) |
| `BOOL` | `True` / `False` |
| `CONTROL` + None | `None` |
| `SHORT_STR` | Raw payload bytes of length `size` (≤15) |
| Anything else | `FATAL(TYPE)` |

No heap allocation in MVP. No LONG_STR walk unless Phase 1b (§8).

### 5.4 Zero-arg `print()`

`argc=0`: emit only `end` (`\n`), push `None`. Matches CPython.

---

## 6. Test strategy

### 6.1 Programs

| Program | Mode | Intent |
| --- | --- | --- |
| `img_print_basic.py` | TWOCORE | `print(1)`, `print(True, None)`, `print("hi")`; return `0` |
| `img_print_empty.py` | TWOCORE | `print()` → blank line |
| `img_print_type_trap.py` | TWOCORE trap | `print([1])` or unsupported tag → TYPE fatal (once defined) |

Keep `managed_entry()` returning INT so existing `EXPECTED_*` checks still apply.

### 6.2 Stdout golden

- Committed golden: `pycore/programs/img_print_basic.stdout` (exact bytes).
- **Do not** use host `print` during `run_image_test` as the oracle (pollutes CI logs and uses CPython formatting). Hand-write goldens (or a small helper that formats the expected text without calling builtin `print` during image gen).
- Sim writes to e.g. `build/img_print_basic/sim.stdout` via TB `$fopen` / `$fwrite` on `CONSOLE_TX`.

### 6.3 Makefile / TB

1. Extend `tb_container.sv` (or `excore_mmio` under `` `ifdef VERILATOR ``) to capture `CONSOLE_TX` writes when `EXCORE_EN=1`.
2. New macro or extend `PYCORE_IMAGE_RUN_TWOCORE` with an optional stdout diff:

   ```make
   # after Vtb_container succeeds:
   diff -u pycore/programs/img_$(1).stdout $(BUILD_DIR)/img_$(1)/sim.stdout
   ```

3. Target: `pycore-img-print-basic: excore-fw` → TWOCORE + stdout diff.
4. Wire into image-test lists / `.PHONY`.

### 6.4 Optional unit / canned tests

- `tb_excore` canned trap: `BUILTIN_CALL` + `BI_PRINT` + one INT arg → expect COMPLETED + None + known bytes if capture wired at that level.
- Host unit test: packing helpers only (no need to simulate MMIO in Python).

### 6.5 Explicit negative

Document that `EXCORE_EN=0` → `CALL_FILTER` (or equivalent fatal). Optional single-core trap test — low priority.

---

## 7. Implementation steps (ordered)

| Step | Work | Owner |
| --- | --- | --- |
| 1 | Spec `CONSOLE_TX` in `mmio_map.md`; decode in `excore_mmio.sv` | excore RTL |
| 2 | TB / Verilator capture to `sim.stdout` | TB |
| 3 | `list_grow.s`: trap 16 dispatch + `do_bi_print` + stringify | excore FW |
| 4 | Rebuild firmware hex (`excore-fw`); update `firmware_build.md` if needed | build |
| 5 | `img_print_basic.py` + `.stdout` + Makefile target | tests |
| 6 | Docs: `builtins.md` status → **in progress** then **implemented**; `architecture.md` note; short `pycore_firmware/builtins/print.md` pointer to this plan | docs |
| 7 | (Phase 2) ROM `CODE_OBJECT` wrapper with `sep=`/`end=`; keep native sink | firmware |

**Likely unchanged for MVP:** CALL FSM marshal, `BI_PRINT` id, builtins dict seed as `OBK_BUILTIN`.

---

## 8. Phases beyond MVP

| Phase | Scope | Exit |
| --- | --- | --- |
| **1 — MVP** | §1–§7: TX + handler + ≤2 args + INT/BOOL/None/SHORT_STR + golden | `img_print_basic` green |
| **1b — LONG_STR** | Slot-read string payload via SP_* port; still native | `print` of a longer literal |
| **2 — Kwargs wrapper** | Replace dict entry with ROM `print(a=None, b=None, …, sep=" ", end="\n")` or similar fixed arity; concatenate; call native 1-arg sink | `print(1, 2, sep=",")` image test |
| **3 — Richer types** | list/tuple/dict repr (firmware or excore); OBJECT `__str__` only after protocol exists | broader goldens |
| **4 — Widen marshal** | Only if native N-arg print is still desired after ROM wrapper: raise `MAX_TRAP_ENTRIES` / document `RES_POP_COUNT` cap | optional |

Phase 2 signature policy (pick one before seeding ROM):

- **P2-A (recommended):** keep native `BI_PRINT` under a private name (`_bi_print`) for the sink; public `print` is ROM with a **small fixed** positional count + `sep`/`end` defaults (matches current stub shape, no `*args`).
- **P2-B:** wait for `CO_VARARGS` then `def print(*args, sep=" ", end="\n")`.

Do **not** seed today’s `print.py` stub (`return 1 % 0`) as ROM until P2 lands.

---

## 9. Risks / open questions (for evaluation)

1. **`argc > 2`:** MVP FATAL vs silently printing E2/E3 only — plan recommends **FATAL**. Agree?
2. **`CONSOLE_TX` at `0xF0`:** any conflict with planned peripherals? Alternative holes: `0xB8–0xBF`, `0xC4–0xCF`.
3. **Capture location:** TB hierarchical spy vs `$fwrite` inside `excore_mmio` under Verilator — prefer TB-side so RTL stays “WO discard.”
4. **Shared trap 16:** handler must id-dispatch; unimplemented `BI_*` stay fatal (not “success”).
5. **Host pollution:** never use live host `print` as the stdout oracle during image build.
6. **CPython parity for BOOL/None:** emit `True`/`False`/`None` (not `1`/`0`) to match host expectations when humans eyeball goldens.
7. **Should MVP support SHORT_STR only via payload bytes** (no escapes)? Yes — raw bytes, like `str` of a short string.
8. **Merge PR target:** implement on `builtins` / a `cursor/print-console-*` branch against `main` once this plan is approved.

---

## 10. Success metric

MVP is done when:

1. Two-core `img_print_basic` returns the expected INT, **and**
2. `sim.stdout` diffs clean against the committed `.stdout` golden, **and**
3. Docs list `print` as implemented (native path) / note kwargs as Phase 2.

That satisfies wave 4 Priority A without waiting for ORD/CHR or bytecode varargs.

---

## 11. Suggested review checklist

When evaluating this plan, please decide:

- [ ] Architecture: hybrid native MVP → ROM kwargs later (**recommend yes**)
- [ ] `argc > 2` policy: FATAL in MVP (**recommend yes**)
- [ ] MMIO offset `0xF0` write-byte TX (**recommend yes**)
- [ ] Types in MVP: INT / BOOL / None / SHORT_STR only (**recommend yes**)
- [ ] Phase 2 signature: P2-A fixed positionals vs wait for `*args`
- [ ] Whether LONG_STR is in MVP or Phase 1b
- [ ] Any change to mailbox layout (stuff `builtin_id` into an entry) — **recommend no for MVP**
