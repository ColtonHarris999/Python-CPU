# Execute fabric: arithmetic units and their latencies

The execute stage (`pycore_exec.sv`) is a tag-routed fabric: `pycore_tag_decode`
picks the unit, `pycore_promote` widens `BOOL -> INT`, `BOOL -> FLOAT`,
`INT -> FLOAT`, the unit runs, and `pycore_exec` folds the result back into
`{tag, value}`. This document covers the arithmetic units behind that
routing: what each one does, how long it takes, how it is verified, and
where its results differ from CPython.

Every unit is plain synchronous RTL on bit vectors. There is no `real`
arithmetic, no `$bitstoreal`, no `**` on wide operands, no combinational
64-bit multiplier or divider. Each unit synthesises with yosys through
sv2v (see "Synthesis" below) and has been checked bit-exactly against a
CPython reference model.

## Handshake

All multi-cycle units share one protocol so that a scoreboard can later
treat them uniformly:

| signal    | dir | meaning                                                                  |
| --------- | --- | ------------------------------------------------------------------------ |
| `start_i` | in  | level: an operation is requested with the operands currently presented   |
| `done_o`  | out | one-cycle pulse; the result outputs are valid in that cycle only         |
| `stall_o` | out | `start_i && !done_o` (minus any trap / exception that ends the request)  |
| `busy_o`  | out | the unit holds state for an accepted request                              |

A request is accepted when `start_i` is high and the unit is neither busy
nor in its `done` cycle, so a requester that keeps `start_i` high and
swaps operands the cycle after `done_o` gets back-to-back operation.
Dropping `start_i` at any time aborts the request and returns the unit to
idle (this is what happens today when the core leaves `S_EXEC`). Traps
(`div_zero_o`, `trap_o`, `exception_o`) are reported with `stall_o` low
and take the place of `done_o`.

The core is still multi-cycle and non-pipelined: `S_EXEC` is held while
`stall_o` is high and the result is consumed in the `done` cycle. Nothing
else in the core had to change for the multi-cycle units. When the
pipeline and scoreboard arrive, `busy_o` / `done_o` are the structural
hazard and completion signals, and the per-stage valid bits inside
`pycore_fp_add` / `pycore_fp_mul` are already there for pipelined issue.

## Units

### Integer

| module             | function                                    | parameters       | latency (cycles)                           |
| ------------------ | ------------------------------------------- | ---------------- | ------------------------------------------ |
| `pycore_int_alu`   | `+ - << >> & \| ^ ~` unary, compares        | -                | 1 (combinational, in the issue cycle)      |
| `pycore_umul_seq`  | unsigned `AW x BW` iterative multiplier core | `AW BW STEP`     | `ceil(BW / STEP) + 1`                      |
| `pycore_mul`       | signed 64 x 64 -> 128 (`*`)                 | `STEP = 16`      | **5**                                      |
| `pycore_udiv_seq`  | unsigned restoring divider core             | `DW VW RL`       | `nsteps + 2`                               |
| `pycore_div`       | signed `//` and `%`, Python floor semantics | `RL = 2`         | **5 + ceil(n / 2)**, n = quotient bits     |
| `pycore_ipow`      | `INT ** INT` square-and-multiply            | shares `pycore_mul` | **4 + 6 k + 5 p** (see below)           |

`pycore_mul` walks the multiplier `STEP` bits per cycle (radix 2^16): one
`64 x 17` signed partial product and an accumulator add per step, four
steps plus the registered result. `STEP = 32` would give 3 cycles with a
`64 x 33` multiplier, `STEP = 8` gives 9 cycles with a `64 x 9` one; the
rest of the design does not care.

`pycore_div` skips leading zeros: only `n = bits(|a|) - bits(|b|) + 1`
quotient bits are iterated (rounded up to a multiple of `RL`), two per
cycle (radix 4: three parallel subtractions of `d`, `2d`, `3d` and a
priority select). The five fixed cycles are accept, leading-zero count /
alignment, core load, core result, and the floor fix-up. `|a| < |b|`
therefore costs 5 cycles, a full 64-bit quotient 37.

`pycore_ipow` with exponent `e > 0` does `k = bits(e) - 1` squarings and
`p = popcount(e) - 1` multiplies, each a full `pycore_mul` pass, plus
four cycles of sequencing. `e == 0` completes in the issue cycle, `e < 0`
traps in the issue cycle. The unit traps `TYPE` as soon as an
intermediate product leaves the signed 64-bit range, so the long chains
only happen for bases `0`, `1`, `-1`.

### Floating point (IEEE 754 binary64)

| module             | function                                        | parameters  | latency (cycles)                               |
| ------------------ | ----------------------------------------------- | ----------- | ---------------------------------------------- |
| `pycore_fp_add`    | `a + b`, `a - b`                                | -           | **4**                                          |
| `pycore_fp_mul`    | `a * b` (53 x 53 on `pycore_umul_seq`)          | `STEP = 14` | **6**                                          |
| `pycore_fp_divrem` | `a / b` (restoring, 56 quotient bits)           | `RL = 2`    | **32**; specials (0, inf, NaN operands) 3      |
| `pycore_fp_divrem` | `fmod(a, b)`, exact (long division by exponent difference `d`) | `RL = 2` | **5 + ceil((d + 1) / 2)** for `d >= 0`; 4 when `|a| < |b|`; specials 3 |
| `pycore_fpu`       | sequencer: scalar ops, `%`, `//`, `**`, compares, COMPLEX | - | see table below                        |

All three datapaths handle subnormal inputs and outputs, signed zeros,
infinities and NaNs, and round to nearest even with a guard / round /
sticky scheme (`pycore_f64_pack_round` in `pycore_fp_defs.svh`). `fmod`
is exact by construction: the remainder is reduced one quotient digit at
a time for `d + 1` bits, which is why `DBL_MAX % 5e-324` takes a thousand
cycles (CPython's libm `fmod` is the same loop in software).

`pycore_fpu` owns one adder, one multiplier and one divider and issues
CPython's exact operation sequences on them:

| operation                   | sequence (CPython reference)                                             | cycles                                         |
| --------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------- |
| `+ - *` `/`                 | pass-through to the datapath                                             | 4 / 4 / 6 / 32                                 |
| compares, `not`, unary `-+` | combinational (`pycore_f64_compare_op`, sign flip)                       | 1                                              |
| `%`                         | `float_rem`: `fmod`, sign fix-up add                                     | `fmod + 2`, `+ 4` when the fix-up add is needed |
| `//`                        | `float_divmod`: `fmod`, `sub`, `div`, `[sub 1]`, `floor`, `sub`, `[add 1]` | `fmod + 44`, `+ 4` per optional step          |
| `**` (integer exponent `n`) | square-and-multiply, `k = bits(|n|) - 1`, `p = popcount(|n|) - 1`        | `6 + 7 k + 6 p`; `+ 32` for `n < 0`; `+ 35 + 7 k + 6 p` instead when `x**|n|` overflowed and `(1/x)**|n|` is recomputed |
| COMPLEX `+ -`               | two adds                                                                 | 10                                             |
| COMPLEX `*`                 | `_Py_c_prod`: four multiplies, two adds                                  | 34                                             |
| COMPLEX `/`                 | `_Py_c_quot` (Smith): three divides, three multiplies, three adds        | 128                                            |
| COMPLEX compares, `not`, `-`| combinational                                                            | 1                                              |

### Measured latencies

`make pycore-alu-units` prints the number of cycles `valid_i` was held for
every operation class it exercised, including the completion cycle. These
are the canonical probes from `tb_alu_units.sv` (`latency_probes`):

```text
probe INT MUL                 5
probe INT // |a|<|b|          5
probe INT // 3-bit/2-bit      6
probe INT // 63-bit/2-bit    36
probe INT % 64-bit/1-bit     37
probe INT 7**1                4
probe INT 2**62              54      (k = 5, p = 4)
probe INT 3**39              49      (k = 5, p = 3)
probe INT (-1)**1001         88      (k = 9, p = 6)
probe INT 1/3                32      (INT -> FLOAT promote is combinational)
probe FLOAT 1.0+3.0           4
probe FLOAT 1.0*3.0           6
probe FLOAT 1.0/3.0          32
probe FLOAT 1.0/inf           3
probe FLOAT 7.5%-3.0         12      (fmod 6, fix-up add)
probe FLOAT 6.0%3.0           8      (fmod 6, no fix-up)
probe FLOAT 1.0%3.0           6      (|a| < |b|)
probe FLOAT 2**52%3.0        33      (d = 51)
probe FLOAT DBL_MAX%min    1056      (d = 2097)
probe FLOAT 7.5//-3.0        54
probe FLOAT 6.0//3.0         50
probe FLOAT 2.0**2           13
probe FLOAT 2.0**100         60      (k = 6, p = 2)
probe FLOAT 2.0**-100        92      (+ reciprocal divide)
probe FLOAT 2.0**-1072      205      (overflow retry path)
probe COMPLEX +              10
probe COMPLEX *              34
probe COMPLEX /             128
```

Random-operand ranges from the same run (3000 iterations per class):
`INT //` 5..37, `INT %` 5..37, `FLOAT //` 14..1098, `FLOAT %` 6..1056,
`COMPLEX /` 1..128 (1 is the NaN / zero-divisor early out). All
compares, unary operations, `INT + - << >> & | ^` and BOOL operations
remain single-cycle.

## Semantics

The units implement CPython 3.14 semantics for the fixed-width values
PyCore has:

- `INT` is the 64-bit wrapping fast path (`architecture.md`): `+ - *`
  wrap, `//` and `%` are floor division on the full range
  (`INT64_MIN // -1` wraps to `INT64_MIN`), `/` promotes both operands
  to binary64 and divides.
- `FLOAT` `+ - * /` are correctly rounded IEEE 754 operations, so they
  match CPython bit for bit. `%` is `float_rem`, `//` is `float_divmod`,
  both as sequences of IEEE operations in CPython's order, so they match
  bit for bit as well. Compares follow IEEE (NaN is unordered; `-0.0 ==
  0.0`).
- `COMPLEX` `+ - * /` are `_Py_c_sum`, `_Py_c_diff`, `_Py_c_prod` and
  the Smith-scaled `_Py_c_quot`, operation for operation.
- Division by zero (`INT // 0`, `INT % 0`, `x / 0.0`, `x % 0.0`,
  `x // 0.0`, `0.0 ** -n`, complex `/ 0j`) traps: `DIV_ZERO` for INT,
  `FPU_EXCEPTION` for FLOAT / COMPLEX.

Deviations (in addition to those in `bytecode_support.md`):

1. **`float ** float` with a non-integer exponent traps `FPU_EXCEPTION`.**
   Hardware has no exp/log; `x ** 0.5` and friends are not computed.
   Integer-valued exponents (`2.0 ** 10`, `x ** -3`, `1e300 ** 2.0`) are.
2. **`float ** int` is square-and-multiply, not libm `pow`.** Results can
   differ from CPython by the accumulated rounding of the chain (a few
   ulp for small exponents; the testbench bounds it at 64 ulp, and at
   `2 n + 8` ulp on the overflow-retry path, where `(1/x) ** n` amplifies
   the reciprocal's rounding). Powers of two and exact small products
   are exact. Overflow to infinity traps `FPU_EXCEPTION`
   (CPython: `OverflowError`).
3. **`int ** int`** traps `TYPE` for a negative exponent (CPython returns a
   float) and when the result leaves 64 bits (CPython promotes to a big
   int). `0 ** 0 == 1`.
4. **Complex `/` has no NaN / infinity recovery.** CPython 3.14's
   `_Py_c_quot` additionally repairs results that came out `nan+nanj`
   when an operand was infinite; the hardware returns the plain Smith
   result.
5. **`INT / INT` and `INT op FLOAT` promote through binary64.** For
   `|int| > 2**53` the conversion rounds, so `(2**53 + 1) / 1` and
   `2**53 + 1 > 2.0**53` can differ from CPython, which compares and
   divides exactly. This is the existing promotion behaviour; the
   conversion itself (`pycore_i64_to_f64`) is correctly rounded.
6. **NaN payloads.** The hardware produces the canonical quiet NaN
   (`0x7FF8_0000_0000_0000`) and propagates operand NaNs by value; it does
   not reproduce the host libm's payload choices. CPython programs cannot
   observe this except through `struct`.

## Verification

`make pycore-alu-units` builds `pycore/tb/tb_alu_units.sv` with the DPI-C
reference model `pycore/tb/alu_ref.c` and runs it (`ALU_UNITS_SEED`,
`ALU_UNITS_ITERS` override the plusargs). The model implements the CPython
semantics above in C on the host's IEEE arithmetic (`-ffp-contract=off`),
so every FLOAT result is compared bit for bit and `**` additionally
against libm `pow`. Each run issues, through `pycore_exec`:

- the `latency_probes` and a directed list of corner cases (rounding
  ties into subnormals, `-0.0`, `INT64_MIN` cases, every trap);
- 3000 random INT / BOOL pairs over every binary and unary operation,
  with operand classes chosen to hit every divider step count and the
  power unit's overflow trap;
- 3000 random FLOAT pairs over `+ - * / // % **` and all compares, with
  zeros, infinities, NaNs, subnormals, `DBL_MAX`, small integers,
  half-integers, mixed `INT` / `BOOL` promotion;
- 1500 random COMPLEX pairs over `+ - * /`, `==`, `!=`, mixed
  real-numeric operands;
- the same again back to back (`valid_i` held, operands swapped in the
  cycle after each completion) to exercise re-arming.

It also asserts that a trap is never raised while `stall_o` is high.
Fifteen seeds (212k checks) pass. `make pycore-exec` and
`make pycore-type-pairs` are the older smoke tests, now waiting on
`stall_o`, and the hardware areas (`make test-hw`) exercise the units
from real bytecode.

## Synthesis

The units are written to synthesise. `yosys 0.52` accepts them after
`sv2v` (the `.svh` headers use SystemVerilog constructs yosys's own
frontend does not parse); `synth` reports no inferred latches. Generic
gate counts and the longest combinational path in two-input gates
(`abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX; ltp -noff`, ripple-carry adders,
so a relative measure only):

| module                         | cells  | flops | longest path (gates) |
| ------------------------------ | ------ | ----- | -------------------- |
| `pycore_mul` (STEP = 16)       | 7.6 k  | 358   | 115                  |
| `pycore_div` (RL = 2)          | 5.8 k  | 727   | 128 (`udiv_seq` step) |
| `pycore_ipow` (without mul)    | 1.6 k  | 202   | 72                   |
| `pycore_fpu` (all FP units)    | 32 k   | 2163  | 153 (`fp_divrem` final normalise), 102 (`fp_add`), 76 (`fp_mul`) |

Each of these paths is one adder-class carry chain plus muxing; there are
no chained adders in a cycle. Knobs if the clock target needs them:
`pycore_mul.STEP` (cycles vs. partial-product width), `DIV_RL` /
`FPU_DIV_RL` (`1` halves the per-step logic and doubles the step count),
`FPU_MUL_STEP`, all parameters of `pycore_exec`.
