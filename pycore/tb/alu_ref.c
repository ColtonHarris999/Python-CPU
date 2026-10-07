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

// ---- pycore_fp_pow, bit for bit -------------------------------------------
// |x| ** y = 2 ** (y log2 |x|) with the same fixed-point digit recurrences
// as the RTL (see pycore_fp_pow.sv); the constants come from the generated
// pow_rom.h shared with the RTL.  Returns the binary64 bit pattern, +inf on
// overflow, +0 on underflow.
#include "pow_rom.h"

typedef unsigned __int128 u128;
typedef __int128 i128;

#define POW_FW   POW_ROM_FW         /* 88 fraction bits                     */
#define POW_NLOG 80
#define POW_NEXP 72
#define POW_LMW  75
#define POW_FP   80
#define POW_LW   (POW_FW + 13)
#define POW_CHAIN_MAX 2             /* pycore_fpu POW_CHAIN_MAX             */

static u128 rom128(const unsigned long long e[2]) { return ((u128)e[0] << 64) | e[1]; }
static u128 rom_pos(int k) { return (k >= 0 && k < POW_ROM_KMAX) ? rom128(pow_rom_pos[k]) : 0; }
static u128 rom_neg(int k) { return (k >= 0 && k < POW_ROM_KMAX) ? rom128(pow_rom_neg[k]) : 0; }

static int bitlen128(u128 v)
{
    int n = 0;
    while (v) { v >>= 1; n++; }
    return n;
}

// pycore_f64_pack_round: value = sig * 2^(exp_s - 1023 - 52), RNE.
static uint64_t pack_round_rtl(int sign, int exp_s, uint64_t sig53, int g, int r, int s)
{
    u128 ext = ((u128)sig53 << 3) | (g << 2) | (r << 1) | s;
    if (ext == 0) return (uint64_t)sign << 63;
    u128 shifted;
    int exp_eff;
    if (exp_s <= 0) {
        int sh = 1 - exp_s;
        if (sh > 55) shifted = 1;
        else {
            u128 lost = ext & (((u128)1 << sh) - 1);
            shifted = (ext >> sh) | (lost ? 1 : 0);
        }
        exp_eff = 1;
    } else {
        shifted = ext;
        exp_eff = exp_s;
    }
    int inc = ((shifted >> 2) & 1) && (((shifted >> 1) & 1) | (shifted & 1) | ((shifted >> 3) & 1));
    uint64_t sig_r = (uint64_t)(shifted >> 3) + (inc ? 1 : 0);
    if (sig_r >> 53) { sig_r >>= 1; exp_eff++; }
    if (exp_eff >= 2047) return ((uint64_t)sign << 63) | 0x7FF0000000000000ull;
    uint64_t e_field = ((sig_r >> 52) & 1) ? (uint64_t)exp_eff : 0;
    return ((uint64_t)sign << 63) | (e_field << 52) | (sig_r & ((1ull << 52) - 1));
}

static void unpack_norm(uint64_t bits, uint64_t *sig, int *exp)
{
    uint64_t e = (bits >> 52) & 0x7FF, f = bits & ((1ull << 52) - 1);
    uint64_t s = e ? (f | (1ull << 52)) : f;
    int ee = e ? (int)e : 1;
    int lz = 0;
    while (!((s >> 52) & 1)) { s <<= 1; lz++; }          // s != 0 here
    *sig = s;
    *exp = ee - lz - 1023;                                // value = sig * 2^(exp - 52)
}

static uint64_t hw_pow_unit(double x, double y)
{
    uint64_t mx, my;
    int ex, ey;
    unpack_norm(d_to_bits(x), &mx, &ex);
    unpack_norm(d_to_bits(y), &my, &ey);
    int ysign = (d_to_bits(y) >> 63) & 1;

    // x = m' 2^E, m' in [2/3, 4/3); r = m' - 1 with POW_FW fraction bits
    i128 r_fx;
    int E;
    if (mx > 0x15555555555555ull) {
        r_fx = -((i128)((1ull << 53) - mx) << (POW_FW - 53));
        E = ex + 1;
    } else {
        r_fx = (i128)(mx & ((1ull << 52) - 1)) << (POW_FW - 52);
        E = ex;
    }

    // signed-digit log2(m') scaled by 2^j0
    i128 acc = 0;
    int j0 = 2;
    u128 mag = r_fx < 0 ? (u128)(-r_fx) : (u128)r_fx;
    if (mag) {
        int s = POW_FW - bitlen128(mag);
        j0 = s < 2 ? 2 : s;
        i128 w = (-r_fx) << j0;
        const i128 half = (i128)1 << (POW_FW - 1), one = (i128)1 << POW_FW;
        for (int i = 0; i < POW_NLOG; i++) {
            int j = j0 + i;
            int d = (w >= half) ? 1 : ((w < -half) ? -1 : 0);
            if (d) {
                i128 wj = (j >= 127) ? (w < 0 ? -1 : 0) : (w >> j);
                if (d == 1) { w = (w - one + wj) << 1; acc -= (i128)(rom_pos(j) >> i); }
                else        { w = (w + one - wj) << 1; acc += (i128)(rom_neg(j) >> i); }
            } else {
                w <<= 1;
            }
        }
    }

    // L = E + acc 2^-j0 as sign / magnitude, normalised to POW_LMW bits
    int lsign, lscale;
    u128 lmag;
    if (E == 0) {
        lsign = acc < 0; lmag = acc < 0 ? (u128)(-acc) : (u128)acc; lscale = j0;
    } else {
        i128 V = ((i128)E << POW_FW) + (acc >> j0);
        lsign = V < 0; lmag = V < 0 ? (u128)(-V) : (u128)V; lscale = 0;
    }
    u128 Lm = 0;
    int eL = 0;
    if (lmag) {
        int lz = POW_LW - bitlen128(lmag);
        Lm = (lmag << lz) >> (POW_LW - POW_LMW);
        eL = (POW_LW - POW_LMW) - lz - POW_FW - lscale;
    }

    // P = y L = Q 2^(ey - 52 + eL), aligned to POW_FP fraction bits
    u128 Q = (u128)my * Lm;
    int sh = ey - 52 + eL + POW_FP;
    u128 Pfix;
    int huge;
    if (sh >= 0) { Pfix = 0; huge = Q != 0; }
    else {
        int t = -sh;
        Pfix = (t >= 128) ? 0 : (Q >> t);
        huge = (Pfix >> (11 + POW_FP)) != 0;
    }
    int psign = ysign ^ lsign;
    if (huge) return psign ? 0 : 0x7FF0000000000000ull;
    i128 Ps = psign ? -(i128)Pfix : (i128)Pfix;
    int I = (int)(Ps >> POW_FP);
    u128 F = ((u128)Ps & (((u128)1 << POW_FP) - 1)) << (POW_FW - POW_FP);

    // 2^F, restoring recurrence
    u128 Z = (u128)1 << POW_FW;
    for (int k = 1; k <= POW_NEXP; k++) {
        u128 c = rom_pos(k) >> k;
        if (F >= c) { F -= c; Z += Z >> k; }
    }
    uint64_t sig = (uint64_t)(Z >> (POW_FW - 52));
    int g  = (int)((Z >> (POW_FW - 53)) & 1);
    int rb = (int)((Z >> (POW_FW - 54)) & 1);
    int st = (Z & (((u128)1 << (POW_FW - 54)) - 1)) != 0;
    return pack_round_rtl(0, I + 1023, sig, g, rb, st);
}

// ---- float ** float as the hardware computes it ---------------------------
// CPython float_pow() special cases; then |a| ** +-1, +-2 by
// square-and-multiply (reciprocal for negative exponents) and every other
// exponent on the log / exp unit; sign restored for odd integer exponents.
// Returns 0 on success, TRAP_FPU for a Python OverflowError /
// ZeroDivisionError, or a negative base with a fractional exponent (a
// complex result in Python, not implemented).
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
    if (!b_is_int && a < 0.0) return TRAP_FPU;  // complex result in Python
    if (abs_a == 1.0) { *out = (a < 0.0 && b_odd) ? -1.0 : 1.0; return 0; }

    double acc;
    if (b_is_int && fabs(b) <= (double)POW_CHAIN_MAX) {
        uint64_t n = (uint64_t)fabs(b);
        acc = sqm_chain(abs_a, n);
        if (b < 0.0) {
            // 1 / x**n, or (1/x)**n when x**n overflowed (result tiny/subnormal).
            if (isinf(acc)) acc = sqm_chain(1.0 / abs_a, n);
            else            acc = 1.0 / acc;
        }
    } else {
        acc = bits_to_d((long long)hw_pow_unit(abs_a, b));
    }
    if (isinf(acc)) return TRAP_FPU;            // OverflowError
    *out = (a < 0.0 && b_odd) ? -acc : acc;
    return 0;
}

// Is the hardware allowed to differ from libm pow() here?  Returns the
// distance in ulps divided by the tolerance for this operand pair, so the
// testbench flags anything above 1.0.  Both the log / exp unit and glibc's
// pow are correctly rounded except within a tiny band around rounding
// boundaries, so they can differ by at most 1 ulp; x ** -2 (1 / (x*x))
// takes two roundings and is allowed 2.
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
    double tol = (b == -2.0) ? 2.0 : 1.0;
    return fabs(hw - lib) / ulp / tol;
}

// Exact agreement with libm pow() (for the statistics the testbench prints).
int alu_ref_pow_exact(long long a_bits, long long b_bits, long long hw_bits)
{
    double a = bits_to_d(a_bits), b = bits_to_d(b_bits);
    double lib = pow(a, b);
    if (isnan(lib)) return isnan(bits_to_d(hw_bits));
    return d_to_bits(lib) == hw_bits;
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
        // CPython 3.14: recover infinities and zeros that computed as
        // nan+nanj (C11 Annex G.5.2 _Cdivd).
        if (isnan(*rr) && isnan(*ri)) {
            if ((isinf(ar) || isinf(ai)) && isfinite(br) && isfinite(bi)) {
                double x = copysign(isinf(ar) ? 1.0 : 0.0, ar);
                double y = copysign(isinf(ai) ? 1.0 : 0.0, ai);
                *rr = INFINITY * (x * br + y * bi);
                *ri = INFINITY * (y * br - x * bi);
            } else if ((isinf(abs_br) || isinf(abs_bi)) && isfinite(ar) && isfinite(ai)) {
                double x = copysign(isinf(br) ? 1.0 : 0.0, br);
                double y = copysign(isinf(bi) ? 1.0 : 0.0, bi);
                *rr = 0.0 * (ar * x + ai * y);
                *ri = 0.0 * (ai * x - ar * y);
            }
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
