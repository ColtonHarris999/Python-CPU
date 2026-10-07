# PyCore limitations

The single tracking list of where PyCore's behaviour differs from CPython
3.14, or where a feature is missing, and what it would cost to lift each
item. Every limitation has a stable id (`L-<area>-<n>`), a status, the
CPython behaviour, the PyCore behaviour, the workaround a program can use
today, and an estimate of the change needed. New limitations are appended
to their area; a lifted one moves to the Resolved section with the commit
that lifted it, so ids are never reused.

Status values:

| Status | Meaning |
| --- | --- |
| **open** | Known difference, no work in progress. |
| **planned** | Design agreed; see the linked plan or section. |
| **accepted** | Intentional for PyCore's fixed-width model; will not change unless the model does. |
| **resolved** | Lifted; kept for history. |

Costs are given as the components that must change (RTL unit, trap /
excore path, ROM firmware, image tooling) and, for RTL, a rough cell and
latency figure from the synthesis flow in `alu.md` §Synthesis. The
hart today is about 86.5k cells / 4.8k flops.

Per-area detail lives next to the design it describes; this document
indexes those lists so there is one place to start:

| Area | Detailed list |
| --- | --- |
| Bytecode semantics (19 deviations: dict / index / slice traps, LEGB, `IS_OP`, compare ceilings, …) | `bytecode_support.md` §Semantic deviations, §Firmware compiler deviations (D1–D13), §Deferred container opcodes |
| Arithmetic units (INT / FLOAT / COMPLEX) | `alu.md` §Semantics (deviations 1–5) |
| On-device `compile()` | `compile_limitations.md` |
| Builtins inventory (in ROM / native / in progress / blocked) | `../../pycore_firmware/builtins/builtins.md` |
| Exception types seeded and trap → raise conversion | `exception_support.md` |
| String accelerator Unicode ceiling | `string_accel.md` §Unicode |

## Arithmetic (L-ALU)

### L-ALU-1 INT arithmetic is 64-bit with trapping, not arbitrary precision

- **Status:** open (fatal trap today; firmware big-int fallback is the lift)
- **CPython:** `int` is arbitrary precision; `2 ** 64`, `10 ** 19`,
  `-(-2 ** 63)` and `INT64_MIN // -1` are ordinary values.
- **PyCore:** every INT result that leaves the signed 64-bit range
  (`+ - *`, unary `-`, `<<`, `**`, `INT64_MIN // -1`) raises
  `PY_TRAP_OVERFLOW` (21), which is fatal. Nothing wraps. `alu.md`
  §Semantics, `bytecode_support.md` deviation 19.
- **Workaround:** keep intermediate values below 2 ** 63 (e.g.
  `pow(a, b, m)` uses doubling instead of a 128-bit product; see
  `pycore_firmware/builtins/pow.py`).
- **To lift:** (1) a heap big-int representation (`OBK_BIGINT` or a
  tagged handle) and a pure-Python firmware library for `+ - * // % **
  << >>`, compare and `str` conversion on 30-bit limbs (~1k lines, ROM
  only); (2) make trap 21 recoverable through the excore path like
  `LIST_GROW`: the excore re-executes the failed `BINARY_OP` through the
  firmware library and writes the result back (`PY_TRAP_BUILTIN_CALL`
  plumbing already exists; ~200 cells of hart glue to expose both
  operands and the opcode); (3) route `BINARY_OP` / `COMPARE_OP` with an
  OBJECT operand of that kind to the same recoverable trap instead of
  `TYPE` (small decode change). No change to the arithmetic units.

### L-ALU-2 `INT / INT` is divided through binary64

- **Status:** open
- **CPython:** `long_true_divide` is correctly rounded for every pair of
  ints (`(2 ** 53 + 1) / 1 == 9007199254740992.0` after a *single*
  rounding of the exact quotient; `(2 ** 60 + 1) / 3` is exact to the last
  bit).
- **PyCore:** both operands are converted to binary64 first (each
  conversion correctly rounded) and then divided: two roundings, so for
  `|operand| > 2 ** 53` the result can differ from CPython by one ulp.
  `alu.md` deviation 4.
- **Workaround:** none in Python; results agree whenever both operands
  are below 2 ** 53 in magnitude (always the case for values that came
  from floats or small ints).
- **To lift:** produce the quotient from the integers directly: a 64 / 64
  sequential division to 55 quotient bits plus a sticky bit in
  `pycore_udiv_seq` (one extra operand-normalising shift, ~300 cells, +64
  cycles only on the `> 2 ** 53` path), then feed `{quotient, sticky}` to
  the existing `pycore_i64_to_f64` rounder.

### L-ALU-3 `INT op FLOAT` compares and operates through binary64

- **Status:** open
- **CPython:** `2 ** 53 + 1 > 2.0 ** 53` is `True`; comparisons between
  `int` and `float` are exact (`float_richcompare` compares the integer
  part and the fraction separately).
- **PyCore:** the INT operand is converted to binary64 (correctly rounded)
  and then compared or combined, so an INT above 2 ** 53 that rounds onto
  the FLOAT compares equal. `alu.md` deviation 4, `bytecode_support.md`
  deviation 17.
- **Workaround:** compare `int(f)` against the int, then the fraction.
- **To lift (compare only):** an exact mixed compare in `pycore_exec`:
  when `|f| < 2 ** 63` convert the FLOAT to a 64-bit integer part plus a
  "has fraction" bit (a 64-bit barrel shifter already exists for
  `f64 -> i64`) and compare integers, adjusting for the fraction; about
  1.5k cells, combinational.
  Arithmetic (`INT + FLOAT`) already matches: CPython also converts the
  int with `PyLong_AsDouble` before operating.

### L-ALU-4 `float ** float` is not libm `pow` bit for bit

- **Status:** accepted
- **CPython:** `float_pow` calls the host libm `pow`, which is correctly
  rounded on glibc.
- **PyCore:** `|x| ** y` is computed in hardware (`alu.md` §Floating
  point) and is correctly rounded except in a thin band around rounding
  boundaries: 99.6 % of random cases agree, the rest differ by 1 ulp.
  `x ** +-1`, `x ** 2`, `x ** 0.5` and `INT ** INT` are exact. `x ** -0.5`
  takes the general path (CPython: libm `pow`, bit-exact only there).
- **To lift:** closing the 1-ulp band needs about 12 more bits in the
  88-bit `log2` / `exp2` datapath and more recurrence digits (`FW`,
  `NLOG` / `NEXP` in `pycore_fp_pow`: ~+15 % of its 19.7k cells and
  ~+25 cycles), or a correctly-rounded fallback on the hard cases, which
  needs an error bound the unit does not compute.

### L-ALU-5 Negative base with a fractional exponent traps

- **Status:** open
- **CPython:** `(-8.0) ** (1 / 3)` is the complex
  `1.0000000000000002+1.7320508075688772j`.
- **PyCore:** `FPU_EXCEPTION` trap. `alu.md` deviation 1.
- **To lift:** see L-ALU-6; it is the same complex `pow`.

### L-ALU-6 No `COMPLEX ** y`

- **Status:** open
- **CPython:** `_Py_c_pow` (polar form via `hypot`, `atan2`, `exp`,
  `log`, `cos`, `sin`; an integer exponent below 100 uses repeated
  squaring).
- **PyCore:** `COMPLEX ** y` traps `FPU_EXCEPTION` (the FPU's complex
  decode has no power case). `+ - * /` are exact `_Py_c_*` sequences.
- **Workaround:** integer exponents by repeated multiplication in Python.
- **To lift:** firmware is possible only if the FPU exposes `exp` / `log`
  / `atan2` / `sin` / `cos` (today `log2` / `exp2` are digit recurrences
  internal to `pycore_fp_pow`, not bytecode-reachable). Cheapest: a
  `BINARY_OP **` COMPLEX path that dispatches a recoverable trap to a
  ROM body for the integer-exponent case (repeated squaring with the
  existing complex multiply), plus native `BI_*` ids for `exp2` / `log2`
  on the pow unit's datapath and a small sequencer for `atan2` / `sincos`
  (~1.5k cells). A transcendental library would then also unblock `math`.

### L-ALU-7 NaN payloads are canonical

- **Status:** accepted
- **CPython:** propagates the host libm's payload choices.
- **PyCore:** always the quiet NaN `0x7FF8_0000_0000_0000`; operand NaNs
  propagate by value. Unobservable without `struct`. `alu.md` deviation 5.

### L-ALU-8 Exception types for arithmetic errors

- **Status:** planned (T5-B / T6 in `exception_support.md`)
- **CPython:** `ZeroDivisionError`, `OverflowError` (`round(inf)`,
  `float ** float` overflow, `10.0 ** 400`), `ValueError`.
- **PyCore:** division by zero and float overflow are traps
  (`DIV_ZERO`, `FPU_EXCEPTION`), not catchable exceptions;
  `OverflowError` is not seeded, so firmware raises `ValueError` where
  CPython raises `OverflowError` (`round(x, n)` overflow, `round(inf)`).
- **To lift:** seed `OverflowError` under `ArithmeticError` (image
  tooling only) and switch the firmware raises; convert the two traps
  through the T6 trap → raise sidecar path already used for `TypeError`.

## Conversions and formatting (L-CONV)

### L-CONV-1 No float → str

- **Status:** open
- **CPython:** `repr(1.1)` / `str` / `print` / f-strings produce the
  shortest round-tripping decimal (`_Py_dg_dtoa` mode 0).
- **PyCore:** `str(x)` on a FLOAT traps `TYPE` (native `str` CALL convert
  handles STR / INT / BOOL / None); `print(1.5)` reaches `_bi_print`,
  whose console path has no FLOAT case; `FORMAT_SIMPLE` on FLOAT traps.
- **Workaround:** print `int(x * 10 ** k)` and the scale.
- **To lift:** firmware can do it with the double-double helpers that
  `float(str)` already seeds (`_two_prod`, `_dd_mul`, `_pow10_dd`):
  scale into `[10 ** 16, 10 ** 17)`, emit 17 digits exactly, then shorten
  by re-parsing candidates with `_float_from_str` (Steele-White style; a
  few thousand cycles per value). The blocker is the hook: the native
  `str` convert and `_bi_print` must dispatch a FLOAT tag to a ROM body
  (one `OBK_TYPE` flag check in the CALL FSM, ~60 cells) and
  `FORMAT_SIMPLE` must take the same route.

### L-CONV-2 `float(str)` beyond 18 significant digits

- **Status:** accepted (firmware)
- **CPython:** `_Py_dg_strtod` is correctly rounded for any digit count.
- **PyCore:** `_float_from_str` accumulates 18 significant digits exactly
  (the INT fast path is 64-bit) and folds the rest into a sticky bit. It
  is bit-exact for all inputs of up to 18 significant digits over the
  whole double range, including subnormals and DBL_MAX, and for longer
  inputs unless the exact value lies within about 1e-18 relative of a
  rounding boundary (for example a 1075-digit exact midpoint between two
  subnormals).
- **To lift:** a second 18-digit limb as a double-double correction
  (~20 lines of firmware, 36 digits) or the big-int library of L-ALU-1
  for exactness.

### L-CONV-3 `round(x, n)` for `|n| > 22`

- **Status:** accepted (firmware)
- **CPython:** exact via `_Py_dg_dtoa` mode 3.
- **PyCore:** bit-exact for `|n| <= 22`, where `10 ** |n|` is an exact
  double and the tie test is exact. Beyond that the power of ten is
  itself rounded and the result can differ in the last place.
  `round(x)` (one argument) is exact for every finite `x`; a result
  outside int64 traps `OVERFLOW` instead of returning a big int
  (L-ALU-1).
- **To lift:** carry `10 ** |n|` as a double-double (`_pow10_dd` is
  already in ROM) in `_round_float`; ~15 lines.

### L-CONV-4 `pow(a, b, m)` for `|m| > 2 ** 62`

- **Status:** accepted (firmware)
- **CPython:** arbitrary precision.
- **PyCore:** `_mulmod` doubles with conditional subtraction so no
  intermediate leaves int64; exact for `|m| <= 2 ** 62`. Larger moduli
  can overflow the `r + a` step and trap `OVERFLOW`.
- **To lift:** L-ALU-1.

### L-CONV-5 `int(str)` is decimal `SHORT_STR` only

- **Status:** open
- **CPython:** any length, `base=`, underscores, whitespace, sign.
- **PyCore:** native `int` CALL convert takes a decimal `SHORT_STR` with
  an optional sign; `base=` and LONG_STR trap `TYPE`.
  `pycore_firmware/builtins/int.py` has a pure-Python `_parse_int_string`
  for bases 2–36 that is not seeded because `int` is an `OBK_TYPE`
  (`int.from_bytes` lives on its `tp_dict`).
- **To lift:** the same FLOAT-style hook as L-CONV-1: let the `int`
  convert fall through to a ROM body for STR tags it does not handle
  (`_bi_code_kind` dispatch inside the body does the rest).

## Builtins and runtime (L-RT)

### L-RT-1 `hash()` is not callable

- **Status:** open
- **CPython:** `hash(x)` for every hashable.
- **PyCore:** the dict / set probe hash is internal to the hart; `hash` is
  a blocked stub. `builtins.md`.
- **To lift:** a native `BI_HASH` id that returns the probe hash for INT
  / BOOL / FLOAT / STR / TUPLE (the hash is already computed on the dict
  path; ~50 cells of result steering) plus the CPython equalities
  `hash(1) == hash(1.0) == hash(True)`.

### L-RT-2 ROM helper names live in the builtins dict

- **Status:** accepted
- **CPython:** a builtin's helpers are module-private.
- **PyCore:** ROM bodies resolve names with `LOAD_GLOBAL` (the calling
  frame's globals, then the boot builtins dict), so every helper a ROM
  body calls is a builtins-dict entry (`_mulmod`, `_round_float`,
  `_float_from_str`, `_dd_mul`, …; `ROM_FIRMWARE_BUILTINS` in
  `image_from_source.py`). A user global of the same name shadows the
  helper for calls made from that module. The names are underscore
  prefixed to keep that unlikely; the same holds for `_bi_*`, `_PYC_G`
  and `_PYC_ENTRY`.
- **To lift:** give ROM code objects their own globals dict (an
  `OBK_FUNCTION` with a globals field, or a second `globals_base_r`
  source for ROM callees), which is also what `bytecode_support.md`
  deviation 6 (full LEGB) needs.

### L-RT-3 Test programs: `JUMP_BACKWARD_NO_INTERRUPT`

- **Status:** open
- **CPython 3.14:** emits `JUMP_BACKWARD_NO_INTERRUPT` for some
  exception-handler exits (two consecutive `try` blocks in one function
  do it).
- **PyCore:** `validate_code_tree` rejects the opcode, so such a function
  cannot be imaged. `bytecode_support.md` D13.
- **Workaround:** move each `try` into its own function
  (`img_fw_float_str.py` does this).
- **To lift:** decode it as `JUMP_BACKWARD` without the eval-breaker
  check (a one-line decode alias).

### L-RT-4 Code ROM budget

- **Status:** open
- **CPython:** no equivalent.
- **PyCore:** the code ROM is 8192 slots (`PYCORE_IMEM_BLOCK_COUNT = 16`,
  64 KB) and holds the boot image, every ROM builtin body and the user
  program. ROM bodies are stored cache-free (`strip_inline_caches`) and
  take ~3.4k slots, so the largest user program that fits is ~4.5k slots
  (`allocator_list` is 3.5k). Each new ROM builtin costs its cache-free
  size; `_float_from_str` + helpers were ~1.2k.
- **To lift:** alternative R1 in `planning/old/compiler_design.md`:
  `PYCORE_IMEM_BLOCK_COUNT` 16 → 32 or 64 moves `CODE_RAM_SLOT_BASE`
  (defined as the ROM slot count) and therefore every `entry_slot` in
  every image and the code-RAM preload of the compiler package;
  `pycore/tests/test_code_ram.py` pins the two together. Mechanical, but
  every image and `image.meta` changes, so it is a deliberate flag day.
  Alternatively place rarely used ROM bodies in code RAM behind the
  compiler package (no RTL change; costs the write-floor guarantee for
  those bodies).

## Design debt (L-PPA)

Items that are not CPython-visible but limit frequency or area.

### L-PPA-1 Native `str(int)` decimal chain is combinational

- **Status:** open
- The INT → decimal conversion in the native `str` CALL convert is a
  combinational divide-by-ten chain, one of the longest paths in the
  core. Lift: make it sequential (one decimal digit per cycle with a
  small constant divider, or double-dabble on a shift register); about
  20 cycles per conversion, and the chain disappears.

### L-PPA-2 LONG_STR compare path depth

- **Status:** open
- The string-compare path through `pycore_exec` is the fabric's longest
  combinational path (419 gates in the `alu.md` ripple-carry measure;
  every arithmetic unit is at or below 171). Lift: a register stage on
  the handle / header compare before the payload `SA_CMP` request; the
  compare is already multi-cycle for LONG_STR, so only the SHORT_STR
  hit path would gain a cycle.

### L-PPA-3 Hierarchical `ltp` artefact across unit ports

- **Status:** accepted
- Yosys `ltp` on the un-flattened FPU reports 520 because it follows
  paths through instance ports that are not real combinational paths;
  flattened it is 171, equal to the pre-change baseline. `alu.md`
  §Synthesis. Read FPU timing from the flattened figure.

## Resolved

### L-CONV-0 `float(str)` had no str-vs-number dispatch — resolved

- Lifted by `_bi_code_kind` (`PY_BI_CODE_KIND = 21`, main) returning the
  raw 4-bit tag as INT: `float` probes the tag and routes SHORT_STR /
  LONG_STR to `_float_from_str`; `round` uses the same probe to tell INT
  / BOOL from FLOAT. Programs: `img_fw_float_str`, `img_fw_round_half_even`.

### L-ALU-0 INT arithmetic wrapped silently — resolved

- `+ - *`, unary `-`, `<<`, `**` and `INT64_MIN // -1` now trap
  `OVERFLOW` (21); negative shift counts trap `VALUE` (22); `INT ** -n`
  returns a FLOAT; `not x` tests the whole value. `alu.md` §Semantics.

### L-RT-0 `round` was half-away-from-zero and float-typed; `pow(a, -b, m)` raised — resolved

- `round` is ties-to-even, returns `int` for one argument and is
  bit-exact for `|n| <= 22`; `pow` follows `long_pow` (sign of `mod`,
  modular inverse, overflow-safe products). `pycore_firmware/builtins/`.
