# `print()` console — implementation plan

**Status:** Done (MVP)  
**Audience:** excore + TB + firmware agents  
**Parent:** `planning/builtins_wave4_plan.md` §1 (Priority A)  
**Unblocks:** stdout-based image tests; Phase 2 LONG_STR streaming

Related:

- ROM body: `pycore_firmware/builtins/print.py`
- Builtin id: `PY_BI_PRINT = 6` (`pycore/rtl/pycore_defs.svh`, `encoding.py`)
- Trap: `PY_TRAP_BUILTIN_CALL = 16` (recoverable)
- Excore FW: `excore/fw/list_grow.s` (`do_bi_print`)
- MMIO: `CONSOLE_TX` @ `0xF0` (`excore/docs/mmio_map.md`)
- CALL binder: `pycore/rtl/pycore_call_fsm.svh` (`CO_VARARGS` + `CALL_KW`)

---

## 1. Goal / non-goals

### Goal

`print(*args, sep=, end=)` on the **two-core** top emits bytes to a console
sink; CI golden-diffs that output while `managed_entry()` still returns INT.

### MVP acceptance (shipped)

```python
def managed_entry():
    print(1)
    print(True, None)
    print("hi")
    print(1, 2, sep=",", end=";")
    print(*xs, sep="-")
    return 0
```

### Non-goals (still Phase 2+)

- `file=` / streams / `open`
- Container / OBJECT `__str__` / `__repr__`
- LONG_STR on the native sink (ROM body never builds a full line — streaming
  `for c in s: _bi_print(c)` stays easy)
- Single-core / `EXCORE_EN=0`

---

## 2. Shipped architecture (hybrid)

```text
builtins["print"] = ROM CODE_OBJECT
     │  *args via CO_VARARGS; sep=/end= via CALL_KW + co_kwdefaults
     ▼
  for each arg (+ sep between): _bi_print(piece)
  _bi_print(end)

builtins["_bi_print"] = OBK_BUILTIN(BI_PRINT)
     │  positional CALL argc=1, EXCORE_EN=1
     ▼
PY_TRAP_BUILTIN_CALL (16) → do_bi_print
     ├─ stringify INT / BOOL / None / SHORT_STR
     ├─ write bytes to CONSOLE_TX @ 0xF0
     └─ COMPLETED → pop 3, push None
```

**Why hybrid:** Python cannot emit host-visible bytes without a sink; kwargs
on `OBK_BUILTIN` stay `CALL_FILTER`, so the public API is a ROM `CODE_OBJECT`.

**Mailbox note:** native sink is **argc=1 only**. Multi-arg / kwargs never
touch the two-arg mailbox limit.

---

## 3. MMIO: `CONSOLE_TX`

| Item | Choice |
| --- | --- |
| Offset | `0xF0` (easy to relocate later) |
| Access | Write-only; low byte = character |
| Capture | TB `$fwrite` on **req pulse** → `STDOUT_PATH` |

---

## 4. CALL binder fixes (varargs + kwargs)

1. After `CO_VARARGS` pack (subs 20–24), `container_idx_r` was left at
   `extra-1`. CALL_KW name binding reuses that index, so with ≥2 positionals
   into `*args` the first kwargs were skipped (defaults applied instead).
   **Fix:** reset `container_idx_r` in sub 24 before `call_after_varargs_sub_r`.

2. Shared dict probe completion (sub 63) treated every `CALL_MODE_EX_KW`
   probe as caller-kwargs order-walk. Filling remaining kw-only defaults
   from `co_kwdefaults` then hung / wrote the wrong slot.
   **Fix:** take the order-walk arm only when `container_base` is the
   caller kwargs dict (`call_kw_names_r`).

Regressions: `img_varargs_kwonly2`, `img_varargs_ex_kw`, `img_print_sep_end`,
`img_print_star_kw`.

---

## 5. Tests

| Program | Notes |
| --- | --- |
| `img_print_empty` | lone `\n` |
| `img_print_basic` | INT / BOOL / None / SHORT_STR |
| `img_print_sep_end` | `sep=` + `end=` |
| `img_print_many` | >2 positionals |
| `img_print_star` / `img_print_star_kw` | CALL_FUNCTION_EX |
| `img_print_neg` / `img_print_bools` | signed INT; BOOL + sep |
| `img_print_type_trap` | list → TYPE |
| `img_varargs_kwonly2*` | binder regression |

Makefile: `PYCORE_IMAGE_RUN_TWOCORE_STDOUT` (skip host print; diff `.stdout`).

Unit: `test_rom_firmware_seed.py` (print kwdefaults / `_bi_print` seed).

---

## 6. Phase 2 (LONG_STR)

Native sink TYPE-traps LONG_STR today. ROM body already streams one piece at
a time; Phase 2 can either:

1. Teach `do_bi_print` to walk LONG_STR bytes to `CONSOLE_TX`, or
2. Keep sink SHORT_STR-only and have ROM iterate characters.

Prefer (1) for speed; (2) needs `ord`/`chr` or char iteration on STR.
