`ifndef PYCORE_FP_DEFS_SVH
`define PYCORE_FP_DEFS_SVH

// IEEE 754 binary64 helpers shared by the FPU (pycore_fpu.sv and its
// pipelines), operand promotion (pycore_promote.sv) and the few core paths
// that compare floats (BI_MAX).  Everything here is plain combinational
// bit manipulation: no `real`, no $bitstoreal / $realtobits, so it
// synthesizes.  Rounding is round-to-nearest-even throughout, which is what
// CPython gets from the host FPU.

localparam logic [63:0] PY_F64_PZERO = 64'h0000_0000_0000_0000;
localparam logic [63:0] PY_F64_NZERO = 64'h8000_0000_0000_0000;
localparam logic [63:0] PY_F64_ONE   = 64'h3FF0_0000_0000_0000;
localparam logic [63:0] PY_F64_NONE  = 64'hBFF0_0000_0000_0000;
localparam logic [63:0] PY_F64_HALF  = 64'h3FE0_0000_0000_0000;
localparam logic [63:0] PY_F64_PINF  = 64'h7FF0_0000_0000_0000;
localparam logic [63:0] PY_F64_NINF  = 64'hFFF0_0000_0000_0000;
localparam logic [63:0] PY_F64_QNAN  = 64'h7FF8_0000_0000_0000;

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------
function automatic logic pycore_f64_is_nan(input logic [63:0] v);
    pycore_f64_is_nan = (v[62:52] == 11'h7FF) && (v[51:0] != 52'd0);
endfunction

function automatic logic pycore_f64_is_inf(input logic [63:0] v);
    pycore_f64_is_inf = (v[62:52] == 11'h7FF) && (v[51:0] == 52'd0);
endfunction

function automatic logic pycore_f64_is_zero(input logic [63:0] v);
    pycore_f64_is_zero = (v[62:0] == 63'd0);
endfunction

function automatic logic pycore_f64_is_finite(input logic [63:0] v);
    pycore_f64_is_finite = (v[62:52] != 11'h7FF);
endfunction

// x < 0 in the C sense: negative, nonzero, not NaN (-0.0 < 0 is false).
function automatic logic pycore_f64_lt_zero(input logic [63:0] v);
    pycore_f64_lt_zero = v[63] && !pycore_f64_is_zero(v) && !pycore_f64_is_nan(v);
endfunction

// Significand with the hidden bit, and the effective biased exponent
// (subnormals use exponent 1 with hidden bit 0, so value =
// sig * 2^(exp - 1023 - 52) holds for every finite input).
function automatic logic [52:0] pycore_f64_sig(input logic [63:0] v);
    pycore_f64_sig = {(v[62:52] != 11'd0), v[51:0]};
endfunction

function automatic logic [10:0] pycore_f64_exp_eff(input logic [63:0] v);
    pycore_f64_exp_eff = (v[62:52] == 11'd0) ? 11'd1 : v[62:52];
endfunction

// ---------------------------------------------------------------------------
// Leading-zero counts (priority encoders; the last assignment wins)
// ---------------------------------------------------------------------------
function automatic logic [6:0] pycore_clz64(input logic [63:0] v);
    pycore_clz64 = 7'd64;
    for (int i = 0; i < 64; i++) begin
        if (v[i]) pycore_clz64 = 7'(63 - i);
    end
endfunction

function automatic logic [5:0] pycore_clz53(input logic [52:0] v);
    pycore_clz53 = 6'd53;
    for (int i = 0; i < 53; i++) begin
        if (v[i]) pycore_clz53 = 6'(52 - i);
    end
endfunction

function automatic logic [5:0] pycore_clz56(input logic [55:0] v);
    pycore_clz56 = 6'd56;
    for (int i = 0; i < 56; i++) begin
        if (v[i]) pycore_clz56 = 6'(55 - i);
    end
endfunction

// ---------------------------------------------------------------------------
// Round-to-nearest-even and pack.
//   value = sig * 2^(exp_s - 1023 - 52) with guard / round / sticky bits
//   below the significand.  sig must be normalized (bit 52 set) unless the
//   whole {sig, g, r, s} is zero or exp_s == 1 (a result that is already in
//   the subnormal range after a bounded left normalization).  exp_s <= 0
//   is denormalized here with a sticky-collecting right shift; exponents
//   that saturate round to infinity.
// ---------------------------------------------------------------------------
function automatic logic [63:0] pycore_f64_pack_round(
    input logic               sign,
    input logic signed [13:0] exp_s,
    input logic [52:0]        sig,
    input logic               g,
    input logic               r,
    input logic               s
);
    logic [55:0]        ext;
    logic [55:0]        shifted;
    logic [55:0]        lost_mask;
    logic signed [13:0] sh;
    logic signed [13:0] exp_eff;
    logic               inc;
    logic [53:0]        sig_r;
    logic [10:0]        e_field;
    begin
        ext = {sig, g, r, s};
        if (ext == 56'd0) begin
            pycore_f64_pack_round = {sign, 63'd0};
        end else begin
            if (exp_s <= 14'sd0) begin
                sh = 14'sd1 - exp_s;
                if (sh > 14'sd55) begin
                    shifted = {55'd0, |ext};
                end else begin
                    lost_mask = (56'd1 << sh[5:0]) - 56'd1;
                    shifted = ext >> sh[5:0];
                    shifted[0] = shifted[0] | (|(ext & lost_mask));
                end
                exp_eff = 14'sd1;
            end else begin
                shifted = ext;
                exp_eff = exp_s;
            end
            // RNE on guard / (round | sticky) / lsb.
            inc   = shifted[2] & (shifted[1] | shifted[0] | shifted[3]);
            sig_r = {1'b0, shifted[55:3]} + {53'd0, inc};
            if (sig_r[53]) begin
                sig_r   = sig_r >> 1;
                exp_eff = exp_eff + 14'sd1;
            end
            if (exp_eff >= 14'sd2047) begin
                pycore_f64_pack_round = {sign, PY_F64_PINF[62:0]};
            end else begin
                // A clear hidden bit only happens at exp_eff == 1, which
                // is exactly the subnormal encoding (exponent field 0).
                e_field = sig_r[52] ? exp_eff[10:0] : 11'd0;
                pycore_f64_pack_round = {sign, e_field, sig_r[51:0]};
            end
        end
    end
endfunction

// ---------------------------------------------------------------------------
// Comparison: returns {unordered, gt, eq, lt}.  +0 == -0; NaN is unordered.
// ---------------------------------------------------------------------------
function automatic logic [3:0] pycore_f64_cmp(input logic [63:0] a, input logic [63:0] b);
    logic lt_mag;
    begin
        if (pycore_f64_is_nan(a) || pycore_f64_is_nan(b)) begin
            pycore_f64_cmp = 4'b1000;
        end else if (pycore_f64_is_zero(a) && pycore_f64_is_zero(b)) begin
            pycore_f64_cmp = 4'b0010;
        end else if (a[63] != b[63]) begin
            pycore_f64_cmp = a[63] ? 4'b0001 : 4'b0100;
        end else if (a[62:0] == b[62:0]) begin
            pycore_f64_cmp = 4'b0010;
        end else begin
            lt_mag = (a[62:0] < b[62:0]);
            // Both negative: the larger magnitude is the smaller value.
            pycore_f64_cmp = (lt_mag ^ a[63]) ? 4'b0001 : 4'b0100;
        end
    end
endfunction

function automatic logic pycore_f64_lt(input logic [63:0] a, input logic [63:0] b);
    pycore_f64_lt = pycore_f64_cmp(a, b)[0];
endfunction

function automatic logic pycore_f64_eq(input logic [63:0] a, input logic [63:0] b);
    pycore_f64_eq = pycore_f64_cmp(a, b)[1];
endfunction

function automatic logic pycore_f64_gt(input logic [63:0] a, input logic [63:0] b);
    pycore_f64_gt = pycore_f64_cmp(a, b)[2];
endfunction

// Evaluate one of the six Python comparison selectors.
function automatic logic pycore_f64_compare_op(
    input logic [4:0]  op,
    input logic [63:0] a,
    input logic [63:0] b
);
    logic [3:0] c;
    begin
        c = pycore_f64_cmp(a, b);
        unique case (op)
            PY_ALU_EQ: pycore_f64_compare_op = c[1];
            PY_ALU_NE: pycore_f64_compare_op = !c[1];
            PY_ALU_LT: pycore_f64_compare_op = c[0];
            PY_ALU_LE: pycore_f64_compare_op = c[0] | c[1];
            PY_ALU_GT: pycore_f64_compare_op = c[2];
            PY_ALU_GE: pycore_f64_compare_op = c[2] | c[1];
            default:   pycore_f64_compare_op = 1'b0;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// floor(): exact, so a 1-cycle combinational function.
// ---------------------------------------------------------------------------
function automatic logic [63:0] pycore_f64_floor(input logic [63:0] a);
    logic [10:0] e;
    logic [5:0]  nfrac;          // fraction bits below the binary point
    logic [51:0] frac_mask;
    logic [62:0] trunc;
    begin
        e = a[62:52];
        if (e == 11'h7FF) begin
            pycore_f64_floor = a;                       // inf / nan
        end else if (e < 11'd1023) begin
            if (pycore_f64_is_zero(a)) pycore_f64_floor = a;
            else                       pycore_f64_floor = a[63] ? PY_F64_NONE : PY_F64_PZERO;
        end else if (e >= 11'd1075) begin
            pycore_f64_floor = a;                       // already integral
        end else begin
            nfrac     = 6'(11'd1075 - e);               // 1..52
            frac_mask = (52'd1 << nfrac) - 52'd1;
            trunc     = {e, a[51:0] & ~frac_mask};
            if (a[63] && ((a[51:0] & frac_mask) != 52'd0)) begin
                // Negative with a fraction: one unit at the integer position.
                // The IEEE encoding is monotonic so the add carries into the
                // exponent field by itself (e.g. -1.5 -> -2.0).
                pycore_f64_floor = {1'b1, trunc + (63'd1 << nfrac)};
            end else begin
                pycore_f64_floor = {a[63], trunc};
            end
        end
    end
endfunction

// True when v is an odd integer (CPython DOUBLE_IS_ODD_INTEGER).
function automatic logic pycore_f64_is_odd_integer(input logic [63:0] v);
    logic [10:0] e;
    begin
        e = v[62:52];
        if (e < 11'd1023 || e >= 11'd1076 || !pycore_f64_is_finite(v)) begin
            pycore_f64_is_odd_integer = 1'b0;           // |v| < 1, or even/huge
        end else if (pycore_f64_floor(v) != v) begin
            pycore_f64_is_odd_integer = 1'b0;
        end else begin
            // Integer: the units bit sits at fraction position 52 - (e-1023)
            // (the hidden bit itself when e == 1023).
            pycore_f64_is_odd_integer = (e == 11'd1023) ? 1'b1
                                      : v[6'(11'd1075 - e)];
        end
    end
endfunction

// ---------------------------------------------------------------------------
// int64 -> binary64 (round-to-nearest-even; |v| > 2^53 loses bits exactly
// the way CPython's PyLong_AsDouble does).
// ---------------------------------------------------------------------------
function automatic logic [63:0] pycore_i64_to_f64(input logic [63:0] v);
    logic        sign;
    logic [63:0] mag;
    logic [6:0]  lz;
    logic [63:0] norm;
    begin
        sign = v[63];
        mag  = sign ? (~v + 64'd1) : v;
        if (mag == 64'd0) begin
            pycore_i64_to_f64 = PY_F64_PZERO;
        end else begin
            lz   = pycore_clz64(mag);
            norm = mag << lz[5:0];
            pycore_i64_to_f64 = pycore_f64_pack_round(
                sign, 14'sd1086 - 14'(lz), norm[63:11], norm[10], norm[9], |norm[8:0]);
        end
    end
endfunction

`endif
