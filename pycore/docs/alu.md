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
| `pycore_int_alu`   | `+ - << >> & \| ^ ~` unary, compares, overflow / domain flags | - | 1 (combinational, in the issue cycle)   |
| `pycore_umul_seq`  | unsigned `AW x BW` iterative multiplier core | `AW BW STEP`     | `ceil(BW / STEP) + 1`                      |
| `pycore_mul`       | signed 64 x 64 -> 128 (`*`)                 | `STEP = 16`      | **5**                                      |
| `pycore_udiv_seq`  | unsigned restoring divider / square-root core | `DW VW RL SQRT` | `nsteps + 2`                               |
| `pycore_div`       | signed `//` and `%`, Python floor semantics | `RL = 2`         | **5 + ceil(n / 2)**, n = quotient bits     |
| `pycore_ipow`      | `INT ** INT`, exponent `>= 0`, square-and-multiply | shares `pycore_mul` | **4 + 6 k + 5 p** (see below)     |

`pycore_int_alu` reports, next to the result, whether it left the signed
64-bit range (`overflow_flag_o`: `+ - unary -`, and `<<` when shifting
back does not recover the operand) and whether an operand was outside
the operation's domain (`value_error_o`: a negative shift count).
`pycore_exec` turns the first into `PY_TRAP_OVERFLOW` for INT-valued
results (compares reuse the subtractor and ignore it), the second into
`PY_TRAP_VALUE`; a 128-bit product whose high word is not the sign
extension of the low word and the quotient `INT64_MIN // -1` trap
`OVERFLOW` the same way. The INT path never wraps silently any more.

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
four cycles of sequencing. `e == 0` completes in the issue cycle. The
unit traps `OVERFLOW` as soon as an intermediate product leaves the
signed 64-bit range, so the long chains only happen for bases `0`, `1`,
`-1`. A negative exponent never reaches the unit: `INT ** INT` with
`e < 0` is a float in Python (`2 ** -1 == 0.5`), and `pycore_exec`
re-routes it to the FPU with both operands promoted to binary64
(`pow_to_float`), so it costs the same as the equivalent `FLOAT **
FLOAT` and returns a `FLOAT`.

### Floating point (IEEE 754 binary64)

| module             | function                                        | parameters  | latency (cycles)                               |
| ------------------ | ----------------------------------------------- | ----------- | ---------------------------------------------- |
| `pycore_fp_add`    | `a + b`, `a - b`                                | -           | **4**                                          |
| `pycore_fp_mul`    | `a * b` (53 x 53 on the FPU's shared `pycore_umul_seq`) | -   | **6**                                          |
| `pycore_fp_divrem` | `a / b` (restoring, 56 quotient bits)           | `RL = 2`    | **32**; specials (0, inf, NaN operands) 3      |
| `pycore_fp_divrem` | `fmod(a, b)`, exact (long division by exponent difference `d`) | `RL = 2` | **5 + ceil((d + 1) / 2)** for `d >= 0`; 4 when `|a| < |b|`; specials 3 |
| `pycore_fp_divrem` | `sqrt(a)`, correctly rounded (restoring, 56 root bits) | `RL = 2` | **32**; specials (0, inf, NaN, negative) 3 |
| `pycore_fp_pow`    | `x ** y = 2 ** (y log2 x)`, shift-and-add log2 / exp2 (see below) | `LMW = 75` (shared multiplier) | **166**; 87 when `x` is a power of two; 15 on overflow / underflow to 0 |
| `pycore_fpu`       | sequencer: scalar ops, `%`, `//`, `**`, compares, COMPLEX; owns the `75 x 53` multiplier | `MUL_STEP = 14`, `POW_CHAIN_MAX = 2` | see table below |

All three datapaths handle subnormal inputs and outputs, signed zeros,
infinities and NaNs, and round to nearest even with a guard / round /
sticky scheme (`pycore_f64_pack_round` in `pycore_fp_defs.svh`). `fmod`
is exact by construction: the remainder is reduced one quotient digit at
a time for `d + 1` bits, which is why `DBL_MAX % 5e-324` takes a thousand
cycles (CPython's libm `fmod` is the same loop in software).

The FPU has exactly one significand multiplier. `pycore_fpu` instantiates
a `75 x 53` `pycore_umul_seq` and muxes it between `pycore_fp_mul`
(`53 x 53`, zero-extended) and `pycore_fp_pow` (`75 x 53`, `L * sig(y)`);
both units expose `mul_start_o / mul_a_o / mul_b_o` and take the product
and `done` back, and the sequencer never has the two active at once. The
widths match so closely that the second multiplier bought nothing but
area (5 k cells of the old 61 k).

Square root lives in the divider: `pycore_udiv_seq` with `SQRT = 1` runs
the restoring recurrence on the same remainder register and the same
three parallel subtractors, with the divisor multiples replaced by the
root-digit candidates `q (8Q + q)` for `q = 1, 2, 3`: `{Q,001}`,
`{Q,0100}` and `{3Q+1,001}`, where `3Q + 1` is kept in its own register
so the digit select drives a mux, not an adder chain.
`pycore_fp_divrem` feeds it the significand (doubled when the
unbiased exponent is odd), takes 56 root bits in 28 radix-4 steps, and
rounds from guard / round / sticky with the final remainder as the
sticky bit, so the result is the correctly rounded `sqrt` -- which is
exactly what CPython's `x ** 0.5` returns (glibc `pow` is correctly
rounded for that exponent). The sequencer routes `x ** 0.5` there: 35
cycles instead of the 171 of the general power unit, and bit-exact
instead of within 1 ulp. The addition to the divider is ~1.1 k cells.

`pycore_fp_pow` evaluates `x ** y` for a positive finite `x` and a finite
`y` as `2 ** (y log2 x)`, with the two transcendental steps as digit
recurrences over one 88-bit fixed-point datapath (two barrel shifters and
two adders per cycle; the only multiplier forms `y * log2 x`):

- **log2** (80 cycles): `x = m' 2^E` with `m'` in `[2/3, 4/3)`, then the
  signed-digit multiplicative normalisation `m' prod(1 + d_j 2^-j) -> 1`,
  `d_j` in `{-1, 0, +1}` chosen from the top bits of the scaled residual
  `w_j = 2^j (1 - x_j)`, and `log2 m' = -sum d_j log2(1 + d_j 2^-j)` with
  the constants from a 2 x 136-entry ROM (`pycore_fp_pow_rom.svh`,
  generated by `pycore/tools/gen_pow_rom.py`). The leading zero digits
  are skipped in one shift and both the residual and the accumulator are
  kept scaled by `2^j0`, so `log2` of an `x` next to 1 keeps full relative
  precision -- `(1 + 2^-52) ** 1e18` needs it.
- **multiply** (5 cycles): `L = E + log2 m'` normalised to 75 bits times
  the 53-bit significand of `y` on the FPU's shared `pycore_umul_seq`; the product is
  aligned to 80 fraction bits, `|P| >= 2^11` is an overflow (`+inf`) or an
  underflow (`+0`) decided right there.
- **exp2** (72 cycles): restoring recurrence on the fraction `F` of `P`:
  whenever `F >= log2(1 + 2^-k)` subtract it and `Z += Z 2^-k`; then
  `Z 2^floor(P)` is rounded to nearest even by the common
  `pycore_f64_pack_round` (subnormals, overflow to `+inf`).

The internal error is below `2^-64` relative in the worst case (results
near the exponent limits) and typically `2^-70`, so the result is the
correctly rounded value except when the exact value lies within that
band of a rounding boundary. glibc's `pow` (which CPython calls) has the
same property with a wider band (its documented bound is 0.52 ulp):
in the randomised runs 99.6 % of the hardware results are bit-identical
to libm and the rest differ by 1 ulp, where a high-precision check shows
the hardware is the correctly rounded side about three times out of four.

`pycore_fpu` owns one adder, one multiplier, one divider (which is also
the square root) and the power unit and issues CPython's exact operation
sequences on them:

| operation                   | sequence (CPython reference)                                             | cycles                                         |
| --------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------- |
| `+ - *` `/`                 | pass-through to the datapath                                             | 4 / 4 / 6 / 32                                 |
| compares, `not`, unary `-+` | combinational (`pycore_f64_compare_op`, sign flip)                       | 1                                              |
| `%`                         | `float_rem`: `fmod`, sign fix-up add                                     | `fmod + 2`, `+ 4` when the fix-up add is needed |
| `//`                        | `float_divmod`: `fmod`, `sub`, `div`, `[sub 1]`, `floor`, `sub`, `[add 1]` | `fmod + 44`, `+ 4` per optional step          |
| `**`, exponent `+-1`, `+-2`  | `float_pow` special cases, then `x`, `x*x`, `1/x`, `1/(x*x)` (square-and-multiply, `POW_CHAIN_MAX`) | 6 / 13 / 38 / 45 (`+ 35 + 7 k + 6 p` when `x**n` overflowed and `(1/x)**n` is recomputed) |
| `**`, exponent `0.5`        | `float_pow` special cases, then `sqrt` on `pycore_fp_divrem`             | **35**                                         |
| `**`, any other exponent    | `float_pow` special cases, then `pycore_fp_pow` on `|x|`, sign for odd integer exponents | `fp_pow + 4..5`: **171**; 91 for a power-of-two base; 19 overflow / underflow |
| COMPLEX `+ -`               | two adds                                                                 | 10                                             |
| COMPLEX `*`                 | `_Py_c_prod`: four multiplies, two adds                                  | 34                                             |
| COMPLEX `/`                 | `_Py_c_quot` (Smith): three divides, three multiplies, three adds        | 128 with finite operands; `+ 1` to inspect the result when an operand holds an infinity, `+ 9` when the inf / zero recovery below runs |
| COMPLEX compares, `not`, `-`| combinational                                                            | 1                                              |

Complex division includes CPython 3.14's recovery of infinities and zeros
(`_Py_c_quot`, after C11 Annex G.5.2): when Smith's algorithm produces
`nan+nanj` and exactly one operand holds an infinity, the result is rebuilt
from signs — `inf*(x*br + y*bi) + inf*(y*br - x*bi)j` for an infinite
numerator, `0.0*(ar*x + ai*y) + 0.0*(ai*x - ar*y)j` for an infinite
denominator, with `x`, `y` in `{+-1, +-0}`. The products are sign /
magnitude selects, so the hardware spends only the two adds on it
(`S_CREC_R`, `S_CREC_I`). The decision is taken from the *operands*
(`crec_cand`), not the result, so divisions with all-finite operands go
straight to `S_DONE` with unchanged timing and no added logic on that
path; only a division with an infinite operand pays one cycle to look at
the result, and nine when it is actually `nan+nanj`.

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
probe FLOAT 3.0**1            6      (square-and-multiply path, n = 1)
probe FLOAT 2.0**2           13      (x * x)
probe FLOAT 3.0**-1          38      (1 / x)
probe FLOAT 3.0**-2          45      (1 / (x * x))
probe FLOAT 3.0**3 (unit)   171      (pycore_fp_pow)
probe FLOAT 3.0**0.5         35      (sqrt on pycore_fp_divrem)
probe FLOAT 3.0**0.25 (unit) 171
probe FLOAT 2.0**100         91      (power-of-two base: log2 stage skipped)
probe FLOAT 2.0**-100        91
probe FLOAT 2.0**-1072       91      (subnormal result)
probe FLOAT 2.0**0.25        91
probe FLOAT 0.5**2^64        19      (underflow decided after the multiply)
probe COMPLEX +              10
probe COMPLEX *              34
probe COMPLEX /             128
probe COMPLEX inf/, no recovery   42   ((inf+0j)/(2+0j): divides on inf finish early)
probe COMPLEX inf/, recovery      71   ((inf+0j)/(1+1j) = inf-infj)
```

Random-operand ranges from the same run (3000 iterations per class):
`INT //` 5..37, `INT %` 5..37, `FLOAT //` 14..1098, `FLOAT %` 6..1056,
`COMPLEX /` 1..128 (1 is the NaN / zero-divisor early out). All
compares, unary operations, `INT + - << >> & | ^` and BOOL operations
remain single-cycle, overflow detection included.

## Semantics

The units implement CPython 3.14 semantics for the fixed-width values
PyCore has:

- `INT` is the signed 64-bit fast path (`architecture.md`). Every
  operation whose exact result fits returns it; one whose result does
  not (`+ - *`, unary `-`, `<<`, `**`, `INT64_MIN // -1`) traps
  `PY_TRAP_OVERFLOW` where CPython would promote to an arbitrary
  precision int -- nothing wraps. `//` and `%` are floor division, `/`
  promotes both operands to binary64 and divides. Shifts follow
  `long_lshift` / `long_rshift`: a negative count traps `PY_TRAP_VALUE`
  (`ValueError: negative shift count`), `a << b` for `b >= 64` is `0`
  when `a == 0` and an overflow otherwise, `a >> b` for `b >= 64` is
  the sign fill (`0` or `-1`); `BOOL` operands are ints (`True << 1 ==
  2`, `8 >> True == 4`).
- `INT ** INT` with a negative exponent is `float.__pow__` on the
  promoted operands (`2 ** -1 == 0.5`, `0 ** -1` traps as `0.0 ** -1`),
  with a `FLOAT` result.
- `not x` tests the whole value for every tag (`not 2` is `False`); a
  `BOOL` operand reaches the BOOL unit as its truth bit, anything else
  as its full value.
- `FLOAT` `+ - * /` are correctly rounded IEEE 754 operations, so they
  match CPython bit for bit. `%` is `float_rem`, `//` is `float_divmod`,
  both as sequences of IEEE operations in CPython's order, so they match
  bit for bit as well. Compares follow IEEE (NaN is unordered; `-0.0 ==
  0.0`).
- `FLOAT ** FLOAT` follows `float_pow`: every special case (`x ** 0`,
  NaNs, infinities, `0.0 ** y`, `+-1 ** y`, the sign of a negative base
  raised to an odd integer) is decided combinationally as in
  floatobject.c, then `|x| ** y` is computed by hardware instead of
  libm `pow` -- see the accuracy note above. Overflow traps
  `FPU_EXCEPTION` (CPython: `OverflowError`), underflow returns `+-0.0`
  like CPython.
- `COMPLEX` `+ - * /` are `_Py_c_sum`, `_Py_c_diff`, `_Py_c_prod` and
  the Smith-scaled `_Py_c_quot` including its 3.14 infinity / zero
  recovery, operation for operation.
- Division by zero (`INT // 0`, `INT % 0`, `x / 0.0`, `x % 0.0`,
  `x // 0.0`, `0.0 ** -n`, complex `/ 0j`) traps: `DIV_ZERO` for INT,
  `FPU_EXCEPTION` for FLOAT / COMPLEX.

Deviations (in addition to those in `bytecode_support.md`; tracked with
costs to lift as `L-ALU-*` in `limitations.md`):

1. **A negative base with a fractional exponent traps `FPU_EXCEPTION`.**
   CPython returns a complex number there (`(-8.0) ** (1/3)` is
   `1.0000000000000002+1.7320508075688772j`); the hardware has no complex
   power.
2. **`float ** float` is not libm's `pow` bit for bit.** Both are
   correctly rounded except in a thin band around rounding boundaries, so
   results agree in 99.6 % of random cases and differ by 1 ulp
   otherwise (hardware the more accurate side about three times out of
   four). `x ** +-1`, `x ** 2` and `x ** 0.5` are the IEEE operations
   themselves (bit-exact); `x ** -2` is `1 / (x*x)` (two roundings,
   within 1 ulp of correctly rounded).
3. **INT results outside signed 64 bits trap `OVERFLOW`** instead of
   becoming big ints: `+ - *`, unary `-`, `<<`, `**` and `INT64_MIN //
   -1`. The trap is fatal until a firmware big-int fallback exists; the
   point of reporting it is that a program can no longer silently
   diverge from CPython. `0 ** 0 == 1`.
4. **`INT / INT` and `INT op FLOAT` promote through binary64.** For
   `|int| > 2**53` the conversion rounds, so `(2**53 + 1) / 1` and
   `2**53 + 1 > 2.0**53` can differ from CPython, which compares and
   divides exactly. This is the existing promotion behaviour; the
   conversion itself (`pycore_i64_to_f64`) is correctly rounded.
5. **NaN payloads.** The hardware produces the canonical quiet NaN
   (`0x7FF8_0000_0000_0000`) and propagates operand NaNs by value; it does
   not reproduce the host libm's payload choices. CPython programs cannot
   observe this except through `struct`.

## Verification

`make pycore-alu-units` builds `pycore/tb/tb_alu_units.sv` with the DPI-C
reference model `pycore/tb/alu_ref.c` and runs it (`ALU_UNITS_SEED`,
`ALU_UNITS_ITERS` override the plusargs). The model implements the CPython
semantics above in C on the host's IEEE arithmetic (`-ffp-contract=off`),
and `pycore_fp_pow`'s fixed-point algorithm bit for bit in 128-bit
integer arithmetic from the same generated ROM (`pycore/tb/pow_rom.h`),
so every FLOAT result -- `**` included -- is compared bit for bit; `**`
is additionally bounded to 1 ulp from libm `pow` (2 for `x ** -2`) and
the run reports how many power results are identical to libm. Each run
issues, through `pycore_exec`:

- the `latency_probes` and a directed list of corner cases (rounding
  ties into subnormals, `-0.0`, `INT64_MIN` cases, every trap: each
  `OVERFLOW` source at both edges, negative and `>= 64` shift counts,
  `BOOL` shifts, `not` on every tag, `INT ** -n`, square roots of
  perfect squares, `1 +- ulp`, subnormals, `2 ** 1023`, `-4.0 ** 0.5`);
- 3000 random INT / BOOL pairs over every binary and unary operation,
  with operand classes chosen to hit every divider step count and the
  overflow traps of every unit;
- 3000 random FLOAT pairs over `+ - * / // % **` and all compares, with
  zeros, infinities, NaNs, subnormals, `DBL_MAX`, small integers,
  half-integers, mixed `INT` / `BOOL` promotion;
- 1000 random `FLOAT ** FLOAT` pairs: bases of every magnitude, next to
  1, negative; exponents small integers, `n / 16`, `0.5`, `|y|` from
  `2^-30` to `2^20`, larger integers and specials, so the log / exp unit
  sees exact, subnormal, overflowing and underflowing results;
- 1500 random COMPLEX pairs over `+ - * /`, `==`, `!=`, mixed
  real-numeric operands, with infinite / NaN components often enough to
  reach the division recovery path;
- the same again back to back (`valid_i` held, operands swapped in the
  cycle after each completion) to exercise re-arming.

It also asserts that a trap is never raised while `stall_o` is high, and
prints how often each trap code was expected by the reference and raised
by the hardware (a typical seed: `DIV_ZERO` ~100, `FPU_EXCEPTION` ~600,
`OVERFLOW` ~500, `VALUE` ~170 of 15.9 k checks), so a trap path that
stopped firing would show up. Twelve seeds (191k checks) pass on the
final RTL. `make pycore-exec` and
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
| `pycore_int_alu`               | 3.8 k  | 0     | 89 (shift-back overflow check) |
| `pycore_mul` (STEP = 16)       | 7.6 k  | 358   | 115                  |
| `pycore_div` (RL = 2)          | 6.1 k  | 727   | 126 (`udiv_seq` step) |
| `pycore_ipow` (without mul)    | 1.6 k  | 202   | 72                   |
| `pycore_fp_divrem` (with sqrt) | 7.9 k  | 820   | 156 (final normalise), 123 (`udiv_seq` step with the sqrt candidates) |
| `pycore_fp_pow` (without mul)  | 19.7 k | 1183  | 171 (91-bit accumulator add) |
| `75 x 53` `pycore_umul_seq`    | 7.1 k  | 364   | 124 (75 x 14 multiply step) |
| `pycore_fpu` (all FP units)    | 57.6 k | 3489  | 171 (`fp_pow`), 156 (`fp_divrem`), 103 (`fp_add`), 76 (`fp_mul`); flattened whole FPU 171 |
| `pycore_exec` (whole fabric)   | 86.5 k | 4776  | 419 (`exec`: the string-compare path, unchanged) |

Against the previous revision the fabric is 2.8 k cells smaller (89.3 k
before): sharing the multiplier saved 5 k, the square root added 1.1 k
in the divider core and 0.3 k in `fp_divrem`, the overflow / shift
checks 0.3 k in `pycore_int_alu` and 0.4 k in `pycore_exec`. The
hierarchical `ltp` number for `pycore_fpu` itself is not meaningful now
that two sub-units hand operands through the sequencer to the shared
multiplier (yosys treats instance ports as pass-through nodes and
reports a 520-gate "path" that crosses the multiplier's registers twice);
flattening the FPU before `ltp` gives 171, the `fp_pow` accumulator.

Each of these paths is one adder-class carry chain plus muxing; there are
no chained adders in a cycle. The power unit's recurrences add 90-bit
numbers, the widest adders in the fabric, which is why it tops the
ripple-carry measure; with the prefix adders a real flow maps to, a
90-bit add is one logic level deeper than a 64-bit one. Knobs if the
clock target needs them: `pycore_mul.STEP` (cycles vs. partial-product
width), `DIV_RL` / `FPU_DIV_RL` (`1` halves the per-step logic and
doubles the step count, for the square root as well), `FPU_MUL_STEP`
(the shared multiplier), all parameters of `pycore_exec`; in
`pycore_fp_pow`, `FW` (datapath width: accuracy vs. adder width),
`NLOG` / `NEXP` (digits: accuracy vs. cycles), and `POW_CHAIN_MAX` in
`pycore_fpu` for how many integer exponents stay on the short
square-and-multiply path.
