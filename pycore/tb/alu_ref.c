// Reference model for tb_alu_units.sv (DPI-C).
//
// Implements the CPython 3.14 semantics the execute fabric is specified
// against, operating on the same tagged operands the fabric sees:
// INT / BOOL / FLOAT / COMPLEX. Every float result is produced with the
// host's IEEE-754 binary64 arithmetic (round-to-nearest-even, no FMA
// contraction), so the hardware must match bit for bit except where
// pycore/docs/alu.md documents a deliberate deviation (handled below).

#include <math.h>
#include <stdint.h>
#include <string.h>

// Verilator compiles user sources with the C++ driver; keep C linkage so
// the DPI import wrappers resolve. Built with -ffp-contract=off.
#ifdef __cplusplus
extern "C" {
#else
#pragma STDC FP_CONTRACT OFF
#endif

// PY_ALU_* (pycore_defs.svh)
enum {
    OP_ADD = 0, OP_SUB, OP_MUL, OP_FLOOR_DIV, OP_TRUE_DIV, OP_MOD, OP_POWER,
    OP_LSHIFT, OP_RSHIFT, OP_AND, OP_OR, OP_XOR, OP_NEG, OP_POS, OP_INVERT,
    OP_NOT, OP_EQ, OP_NE, OP_LT, OP_LE, OP_GT, OP_GE, OP_PASS
};

// PY_TAG_* (pycore_defs.svh)
enum { TAG_INT = 1, TAG_FLOAT = 2, TAG_COMPLEX = 3, TAG_BOOL = 4, TAG_OBJECT = 10 };

// PY_TRAP_* (pycore_defs.svh)
enum { TRAP_NONE = 0, TRAP_TYPE = 1, TRAP_DIV_ZERO = 3, TRAP_FPU = 4 };

static double bits_to_d(long long b) { double d; memcpy(&d, &b, 8); return d; }
static long long d_to_bits(double d) { long long b; memcpy(&b, &d, 8); return b; }

static int is_compare(int op) { return op >= OP_EQ && op <= OP_GE; }

static int cmp_result(int op, int lt, int eq, int gt, int unordered)
{
    if (unordered) return op == OP_NE;
    switch (op) {
    case OP_EQ: return eq;
    case OP_NE: return !eq;
    case OP_LT: return lt;
    case OP_LE: return lt || eq;
    case OP_GT: return gt;
    case OP_GE: return gt || eq;
    }
    return 0;
}

// ---- float ** float as the hardware computes it ---------------------------
// Square-and-multiply on |a| with the integer exponent |n| (MSB first),
// reciprocal for negative exponents, sign restored for odd exponents.
// Returns 0 on success, TRAP_FPU for a Python OverflowError /
// ZeroDivisionError / unsupported (non-integer) exponent.
static double sqm_chain(double base, uint64_t n)
{
    int msb = 63;
    while (!((n >> msb) & 1)) msb--;
    double acc = base;
    for (int i = msb - 1; i >= 0; i--) {
        acc = acc * acc;
        if ((n >> i) & 1) acc = acc * base;
    }
    return acc;
}

static int hw_float_pow(double a, double b, double *out)
{
    double abs_a = fabs(a);
    if (b == 0.0) { *out = 1.0; return 0; }
    if (isnan(a)) { *out = a; return 0; }
    if (isnan(b)) { *out = (a == 1.0) ? 1.0 : b; return 0; }
    if (isinf(b)) {
        if (abs_a == 1.0) *out = 1.0;
        else if ((b > 0.0) == (abs_a > 1.0)) *out = INFINITY;
        else *out = 0.0;
        return 0;
    }
    int b_is_int = (floor(b) == b);
    int b_odd = b_is_int && fabs(b) < 9007199254740992.0 && fmod(fabs(b), 2.0) == 1.0;
    if (isinf(a)) {
        if (b > 0.0) *out = b_odd ? a : abs_a;
        else *out = b_odd ? copysign(0.0, a) : 0.0;
        return 0;
    }
    if (a == 0.0) {
        if (b < 0.0) return TRAP_FPU;           // ZeroDivisionError
        *out = b_odd ? a : 0.0;
        return 0;
    }
    if (!b_is_int || fabs(b) >= 9223372036854775808.0) return TRAP_FPU;
    if (abs_a == 1.0) { *out = (a < 0.0 && b_odd) ? -1.0 : 1.0; return 0; }

    uint64_t n = (uint64_t)fabs(b);
    double acc = sqm_chain(abs_a, n);
    if (b < 0.0) {
        // 1 / x**n, or (1/x)**n when x**n overflowed (result tiny/subnormal).
        if (isinf(acc)) acc = sqm_chain(1.0 / abs_a, n);
        else            acc = 1.0 / acc;
    }
    if (isinf(acc)) return TRAP_FPU;            // OverflowError
    *out = (a < 0.0 && (n & 1)) ? -acc : acc;
    return 0;
}

// Is the hardware allowed to differ from libm pow() here?  Only by the
// accumulated rounding of the square-and-multiply chain. Returns the
// distance in ulps divided by the tolerance for this operand pair, so the
// testbench flags anything above 1.0. The tolerance is 64 ulps for the
// direct chain and (2n + 8) for the (1/x)**n retry, whose initial rounding
// error is amplified n times.
double alu_ref_pow_ulps(long long a_bits, long long b_bits, long long hw_bits)
{
    double a = bits_to_d(a_bits), b = bits_to_d(b_bits), hw = bits_to_d(hw_bits);
    double lib = pow(a, b);
    if (isnan(lib) || isnan(hw)) return (isnan(lib) && isnan(hw)) ? 0.0 : 1e30;
    if (isinf(lib) || isinf(hw))
        return (lib == hw) ? 0.0 : 1e30;
    int e;
    frexp(lib, &e);
    double ulp = ldexp(1.0, e - 53);
    if (lib == 0.0 || ulp < 0x1p-1074) ulp = 0x1p-1074;   // subnormal spacing
    double tol = 64.0;
    if (b < 0.0 && floor(b) == b && fabs(b) < 9223372036854775808.0 &&
        isinf(sqm_chain(fabs(a), (uint64_t)fabs(b))))
        tol = 2.0 * fabs(b) + 8.0;
    return fabs(hw - lib) / ulp / tol;
}

// ---- CPython float_rem / float_divmod -------------------------------------
static double py_float_rem(double vx, double wx)
{
    double mod = fmod(vx, wx);
    if (mod) {
        if ((wx < 0) != (mod < 0)) mod += wx;
    } else {
        mod = copysign(0.0, wx);
    }
    return mod;
}

static double py_float_floordiv(double vx, double wx)
{
    double mod = fmod(vx, wx);
    double div = (vx - mod) / wx;
    double floordiv;
    if (mod) {
        if ((wx < 0) != (mod < 0)) { mod += wx; div -= 1.0; }
    } else {
        mod = copysign(0.0, wx);
    }
    if (div) {
        floordiv = floor(div);
        if (div - floordiv > 0.5) floordiv += 1.0;
    } else {
        floordiv = copysign(0.0, vx / wx);
    }
    return floordiv;
}

// ---- scalar float op --------------------------------------------------------
static int float_op(int op, double a, double b, int *res_tag, double *r)
{
    *res_tag = TAG_FLOAT;
    switch (op) {
    case OP_ADD: *r = a + b; return 0;
    case OP_SUB: *r = a - b; return 0;
    case OP_MUL: *r = a * b; return 0;
    case OP_TRUE_DIV:
        if (b == 0.0) return TRAP_FPU;
        *r = a / b; return 0;
    case OP_MOD:
        if (b == 0.0) return TRAP_FPU;
        *r = py_float_rem(a, b); return 0;
    case OP_FLOOR_DIV:
        if (b == 0.0) return TRAP_FPU;
        *r = py_float_floordiv(a, b); return 0;
    case OP_POWER:
        return hw_float_pow(a, b, r);
    case OP_NEG: *r = -a; return 0;
    case OP_POS: case OP_PASS: *r = a; return 0;
    case OP_NOT:
        *res_tag = TAG_BOOL; *r = (a == 0.0) ? 1.0 : 0.0; return 0;
    case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE:
        *res_tag = TAG_BOOL;
        *r = cmp_result(op, a < b, a == b, a > b, isnan(a) || isnan(b)) ? 1.0 : 0.0;
        return 0;
    }
    return TRAP_TYPE;
}

// ---- complex op (_Py_c_sum / _Py_c_diff / _Py_c_prod / _Py_c_quot) ---------
static int complex_op(int op, double ar, double ai, double br, double bi,
                      int *res_tag, double *rr, double *ri)
{
    *res_tag = TAG_COMPLEX;
    switch (op) {
    case OP_ADD: *rr = ar + br; *ri = ai + bi; return 0;
    case OP_SUB: *rr = ar - br; *ri = ai - bi; return 0;
    case OP_MUL:
        *rr = (ar * br) - (ai * bi);
        *ri = (ar * bi) + (ai * br);
        return 0;
    case OP_TRUE_DIV: {
        double abs_br = fabs(br), abs_bi = fabs(bi);
        if (abs_br >= abs_bi) {
            if (abs_br == 0.0) return TRAP_FPU;     // ZeroDivisionError
            double ratio = bi / br;
            double denom = br + bi * ratio;
            *rr = (ar + ai * ratio) / denom;
            *ri = (ai - ar * ratio) / denom;
        } else if (abs_bi >= abs_br) {
            double ratio = br / bi;
            double denom = br * ratio + bi;
            *rr = (ar * ratio + ai) / denom;
            *ri = (ai * ratio - ar) / denom;
        } else {
            *rr = NAN; *ri = NAN;
        }
        return 0;
    }
    case OP_NEG: *rr = -ar; *ri = -ai; return 0;
    case OP_POS: case OP_PASS: *rr = ar; *ri = ai; return 0;
    case OP_NOT:
        *res_tag = TAG_BOOL; *rr = (ar == 0.0 && ai == 0.0) ? 1.0 : 0.0; *ri = 0.0; return 0;
    case OP_EQ:
        *res_tag = TAG_BOOL; *rr = (ar == br && ai == bi) ? 1.0 : 0.0; *ri = 0.0; return 0;
    case OP_NE:
        *res_tag = TAG_BOOL; *rr = (ar == br && ai == bi) ? 0.0 : 1.0; *ri = 0.0; return 0;
    }
    return TRAP_TYPE;
}

// ---- integer op (64-bit wrapping fast path) ---------------------------------
static int int_op(int op, int64_t a, int64_t b, int bool_bool, int *res_tag, int64_t *r)
{
    *res_tag = TAG_INT;
    uint64_t ua = (uint64_t)a, ub = (uint64_t)b;
    switch (op) {
    case OP_ADD: *r = (int64_t)(ua + ub); return 0;
    case OP_SUB: *r = (int64_t)(ua - ub); return 0;
    case OP_MUL: *r = (int64_t)(ua * ub); return 0;
    case OP_FLOOR_DIV:
    case OP_MOD: {
        if (b == 0) return TRAP_DIV_ZERO;
        // Python floor semantics on the full 64-bit range.
        __int128 q = (__int128)a / b;
        __int128 m = (__int128)a - q * b;
        if (m != 0 && ((m < 0) != (b < 0))) { q -= 1; m += b; }
        *r = (op == OP_MOD) ? (int64_t)m : (int64_t)q;
        return 0;
    }
    case OP_POWER: {
        if (b < 0) return TRAP_TYPE;
        __int128 acc = 1;
        for (int64_t i = 0; i < b; i++) {
            acc = acc * a;
            if (acc > INT64_MAX || acc < INT64_MIN) return TRAP_TYPE;
            if (acc == 0 || acc == 1) break;        // stays put; also bounds the loop
            if (acc == -1 && a == -1) {
                // (-1)**b: sign depends on parity of the remaining exponent
                int64_t remaining = b - i - 1;
                acc = (remaining % 2 == 0) ? -1 : 1;
                break;
            }
        }
        *r = (int64_t)acc;
        return 0;
    }
    case OP_LSHIFT:
        if (b < 0 || b >= 64) *r = 0; else *r = (int64_t)(ua << b);
        return 0;
    case OP_RSHIFT:
        if (b < 0) *r = 0; else if (b >= 64) *r = (a < 0) ? -1 : 0; else *r = a >> b;
        return 0;
    case OP_AND:
        if (bool_bool) *res_tag = TAG_BOOL;
        *r = a & b; return 0;
    case OP_OR:
        if (bool_bool) *res_tag = TAG_BOOL;
        *r = a | b; return 0;
    case OP_XOR:
        if (bool_bool) *res_tag = TAG_BOOL;
        *r = a ^ b; return 0;
    case OP_NEG: *r = (int64_t)(0 - ua); return 0;
    case OP_POS: case OP_PASS: *r = a; return 0;
    case OP_INVERT: *r = ~a; return 0;
    case OP_NOT: *res_tag = TAG_BOOL; *r = (a == 0); return 0;
    case OP_EQ: case OP_NE: case OP_LT: case OP_LE: case OP_GT: case OP_GE:
        *res_tag = TAG_BOOL;
        *r = cmp_result(op, a < b, a == b, a > b, 0);
        return 0;
    }
    return TRAP_TYPE;
}

static double numeric_as_double(int tag, long long lo)
{
    if (tag == TAG_FLOAT) return bits_to_d(lo);
    if (tag == TAG_BOOL) return (lo & 1) ? 1.0 : 0.0;
    return (double)(int64_t)lo;   // INT, RNE conversion like pycore_i64_to_f64
}

static int is_binary(int op)
{
    return op <= OP_XOR || is_compare(op);
}

// Entry point. Operands are 128-bit values split in two 64-bit halves
// (COMPLEX: lo = real, hi = imag).  Returns the trap code (0 = none) and,
// when there is none, the result tag and value.
int alu_ref(int op, int tag_a, long long a_lo, long long a_hi,
            int tag_b, long long b_lo, long long b_hi,
            int *res_tag, long long *r_lo, long long *r_hi)
{
    *res_tag = TAG_OBJECT; *r_lo = 0; *r_hi = 0;
    int binary = is_binary(op);
    int tb = binary ? tag_b : TAG_INT;

    if (tag_a == TAG_COMPLEX || tb == TAG_COMPLEX) {
        if (op == OP_FLOOR_DIV || op == OP_MOD || op == OP_POWER ||
            op == OP_LSHIFT || op == OP_RSHIFT || op == OP_AND || op == OP_OR ||
            op == OP_XOR || op == OP_INVERT || (is_compare(op) && op != OP_EQ && op != OP_NE))
            return TRAP_TYPE;
        double ar, ai = 0.0, br = 0.0, bi = 0.0;
        if (tag_a == TAG_COMPLEX) { ar = bits_to_d(a_lo); ai = bits_to_d(a_hi); }
        else ar = numeric_as_double(tag_a, a_lo);
        if (binary) {
            if (tag_b == TAG_COMPLEX) { br = bits_to_d(b_lo); bi = bits_to_d(b_hi); }
            else br = numeric_as_double(tag_b, b_lo);
        }
        double rr, ri;
        int t = complex_op(op, ar, ai, br, bi, res_tag, &rr, &ri);
        if (t) return t;
        if (*res_tag == TAG_BOOL) { *r_lo = (rr != 0.0); }
        else { *r_lo = d_to_bits(rr); *r_hi = d_to_bits(ri); }
        return 0;
    }

    if (tag_a == TAG_FLOAT || tb == TAG_FLOAT) {
        if (op == OP_LSHIFT || op == OP_RSHIFT || op == OP_AND || op == OP_OR ||
            op == OP_XOR || op == OP_INVERT)
            return TRAP_TYPE;
        double a = numeric_as_double(tag_a, a_lo);
        double b = binary ? numeric_as_double(tag_b, b_lo) : 0.0;
        double r;
        int t = float_op(op, a, b, res_tag, &r);
        if (t) return t;
        if (*res_tag == TAG_BOOL) *r_lo = (r != 0.0);
        else *r_lo = d_to_bits(r);
        return 0;
    }

    // INT / BOOL
    if (op == OP_TRUE_DIV) {
        double a = numeric_as_double(tag_a, a_lo);
        double b = numeric_as_double(tag_b, b_lo);
        if (b == 0.0) return TRAP_FPU;
        *res_tag = TAG_FLOAT;
        *r_lo = d_to_bits(a / b);
        return 0;
    }
    int64_t a = (tag_a == TAG_BOOL) ? (a_lo & 1) : (int64_t)a_lo;
    int64_t b = binary ? ((tag_b == TAG_BOOL) ? (b_lo & 1) : (int64_t)b_lo) : 0;
    int bool_bool = (tag_a == TAG_BOOL) && (tb == TAG_BOOL);
    if ((op == OP_LSHIFT || op == OP_RSHIFT) && (tag_a != TAG_INT || tag_b != TAG_INT))
        return TRAP_TYPE;
    int64_t r;
    int t = int_op(op, a, b, bool_bool, res_tag, &r);
    if (t) return t;
    if (op == OP_PASS) *res_tag = tag_a;
    if (bool_bool && (op == OP_EQ || op == OP_NE)) *res_tag = TAG_BOOL;
    *r_lo = r;
    if (*res_tag == TAG_INT) *r_hi = (r < 0) ? -1 : 0;
    return 0;
}

// Host libm helpers for directed checks in the testbench.
long long alu_ref_fmod(long long a, long long b) { return d_to_bits(fmod(bits_to_d(a), bits_to_d(b))); }
long long alu_ref_floor(long long a) { return d_to_bits(floor(bits_to_d(a))); }
long long alu_ref_i64_to_f64(long long a) { return d_to_bits((double)a); }

#ifdef __cplusplus
}
#endif
