`include "pycore_defs.svh"

// IEEE 754 binary64 divide, C fmod() and square root, sharing one
// radix-2**RL restoring core (pycore_udiv_seq) on the 53-bit significands.
//
//   C0            unpack, normalize subnormal significands   -> stage 1 regs
//   C1            exponent difference, load the divider core
//   C2 .. C(S+1)  S restoring steps (DIV: 56 quotient bits -> 28 at RL = 2;
//                 SQRT: 56 root bits -> 28 at RL = 2 (55 -> 55 at RL = 1);
//                 FMOD: exponent difference + 1 bits, so S depends on the
//                 operands and is bounded by ~1050 at RL = 2)
//   C(S+2)        core registers quotient / remainder
//   C(S+3)        round / normalize, pack                     -> result_o
//
// DIV and SQRT therefore take 32 cycles at RL = 2 (accept cycle included),
// both correctly rounded (the remainder is the sticky bit).  FMOD is
// exact (no rounding) and takes 4 + ceil((d+1)/2) cycles for exponent
// difference d >= 0, or 3 cycles when |a| < |b|.  Specials (NaN, inf,
// zero divisor) finish in 3 cycles.  The divisor-is-zero case returns the
// IEEE value; the FPU sequencer raises the Python ZeroDivisionError trap
// before it ever reaches this unit.  sqrt of a negative number returns
// NaN (the FPU never asks: a negative base with exponent 0.5 is a complex
// result in Python and traps earlier).
//
// Handshake as in pycore_umul_seq.sv.
module pycore_fp_divrem #(
    parameter int RL = 2
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic        fmod_i,          // 0: a / b, 1: fmod(a, b)
    input  logic        sqrt_i,          // 1: sqrt(a) (fmod_i must be 0)
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,
    output logic        done_o,
    output logic        busy_o
);

    localparam int DIV_STEPS  = 56 / RL;
    localparam int SQRT_STEPS = (RL == 2) ? 28 : 55;   // root bits = 56 / 55
    localparam int RW = 57;                             // remainder width (sqrt: < 2Q + 1)

    // ---------------- C0: unpack / normalize ----------------
    logic               s1_valid_r;
    logic               s1_fmod_r;
    logic               s1_sqrt_r;
    logic               s1_sign_r;          // quotient sign / a's sign for fmod
    logic signed [13:0] s1_exp_a_r, s1_exp_b_r;
    logic [52:0]        s1_sig_a_r, s1_sig_b_r;
    logic               s1_special_r;
    logic [63:0]        s1_special_val_r;
    logic [63:0]        s1_a_r;

    logic [52:0] sig_a, sig_b;
    logic [5:0]  lz_a, lz_b;
    logic        a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
    logic        qsign;
    logic        special;
    logic [63:0] special_val;

    assign sig_a  = pycore_f64_sig(op_a_i);
    assign sig_b  = pycore_f64_sig(op_b_i);
    assign lz_a   = pycore_clz53(sig_a);
    assign lz_b   = pycore_clz53(sig_b);
    assign a_nan  = pycore_f64_is_nan(op_a_i);
    assign b_nan  = pycore_f64_is_nan(op_b_i);
    assign a_inf  = pycore_f64_is_inf(op_a_i);
    assign b_inf  = pycore_f64_is_inf(op_b_i);
    assign a_zero = pycore_f64_is_zero(op_a_i);
    assign b_zero = pycore_f64_is_zero(op_b_i);
    assign qsign  = op_a_i[63] ^ op_b_i[63];

    always_comb begin
        special     = 1'b0;
        special_val = PY_F64_QNAN;
        if (sqrt_i) begin
            if (a_nan || op_a_i[63] && !a_zero) begin
                special = 1'b1;                       // nan
            end else if (a_inf || a_zero) begin
                special     = 1'b1;
                special_val = op_a_i;                 // +inf, +-0
            end
        end else if (a_nan || b_nan) begin
            special = 1'b1;
        end else if (fmod_i) begin
            if (a_inf || b_zero) begin
                special = 1'b1;                       // nan
            end else if (b_inf || a_zero) begin
                special     = 1'b1;
                special_val = op_a_i;
            end
        end else begin
            if (a_inf && b_inf) begin
                special = 1'b1;                       // nan
            end else if (a_inf) begin
                special     = 1'b1;
                special_val = {qsign, PY_F64_PINF[62:0]};
            end else if (b_inf) begin
                special     = 1'b1;
                special_val = {qsign, 63'd0};
            end else if (b_zero) begin
                special     = 1'b1;
                special_val = a_zero ? PY_F64_QNAN : {qsign, PY_F64_PINF[62:0]};
            end else if (a_zero) begin
                special     = 1'b1;
                special_val = {qsign, 63'd0};
            end
        end
    end

    // ---------------- C1: load the divider ----------------
    logic signed [13:0] d;                  // exponent difference (fmod)
    logic signed [13:0] n_bits;             // radix-2 steps for fmod
    logic               fmod_small;         // |a| < |b|: result is a
    logic               pad;                // odd step count at radix 4
    logic [RW-1:0]      rem_init;
    logic [55:0]        bits;
    logic [15:0]        nsteps;

    assign d          = s1_exp_a_r - s1_exp_b_r;
    assign n_bits     = d + 14'sd1;
    assign fmod_small = s1_fmod_r && (d < 14'sd0);
    assign pad        = (RL == 2) && n_bits[0];

    always_comb begin
        if (s1_sqrt_r) begin
            // Radicand 2^(e - 52) * sig with the unbiased e = ea - 1023 made
            // even: sig' = sig or 2 sig (54 bits), left-aligned so the steps
            // take it in 2*RL-bit groups from the top.  e is odd when the
            // biased ea is even.
            rem_init = '0;
            bits     = !s1_exp_a_r[0] ? {s1_sig_a_r, 3'b000} : {1'b0, s1_sig_a_r, 2'b00};
            nsteps   = 16'(SQRT_STEPS);
        end else if (!s1_fmod_r) begin
            rem_init = RW'(s1_sig_a_r >> 1);
            bits     = {s1_sig_a_r[0], 55'd0};
            nsteps   = 16'(DIV_STEPS);
        end else if (pad) begin
            rem_init = RW'(s1_sig_a_r >> 2);
            bits     = {s1_sig_a_r[1:0], 54'd0};
            nsteps   = 16'(14'(n_bits + 14'sd1) >>> 1);
        end else begin
            rem_init = RW'(s1_sig_a_r >> 1);
            bits     = {s1_sig_a_r[0], 55'd0};
            nsteps   = (RL == 2) ? 16'(n_bits >>> 1) : 16'(n_bits);
        end
    end

    logic        core_start;
    logic        core_busy, core_done;
    logic [55:0] quot;
    logic [RW-1:0] rem;
    logic        fin_r;                      // special / small result in C2
    logic        s2_fmod_r;
    logic        s2_sqrt_r;
    logic        s2_sign_r;
    logic signed [13:0] s2_exp_r;            // DIV: ea - eb + 1023; FMOD: eb
    logic        s2_special_r;
    logic [63:0] s2_special_val_r;

    assign core_start = start_i && !fin_r &&
                        ((s1_valid_r && !s1_special_r && !fmod_small) || core_busy);

    pycore_udiv_seq #(.DW(56), .VW(RW), .RL(RL), .SQRT(1'b1)) u_div (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),
        .start_i    (core_start),
        .sqrt_i     (s1_sqrt_r),
        .rem_init_i (rem_init),
        .bits_i     (bits),
        .divisor_i  (RW'(s1_sig_b_r)),
        .nsteps_i   (nsteps),
        .quotient_o (quot),
        .remainder_o(rem),
        .done_o     (core_done),
        .busy_o     (core_busy)
    );

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            s1_valid_r <= 1'b0; s1_fmod_r <= 1'b0; s1_sqrt_r <= 1'b0; s1_sign_r <= 1'b0;
            s1_exp_a_r <= '0; s1_exp_b_r <= '0; s1_sig_a_r <= '0; s1_sig_b_r <= '0;
            s1_special_r <= 1'b0; s1_special_val_r <= '0; s1_a_r <= '0;
            fin_r <= 1'b0; s2_fmod_r <= 1'b0; s2_sqrt_r <= 1'b0; s2_sign_r <= 1'b0; s2_exp_r <= '0;
            s2_special_r <= 1'b0; s2_special_val_r <= '0;
        end else if (!start_i) begin
            s1_valid_r <= 1'b0;
            fin_r      <= 1'b0;
        end else begin
            s1_valid_r <= start_i && !busy_o;
            if (start_i && !busy_o) begin
                s1_fmod_r        <= fmod_i;
                s1_sqrt_r        <= sqrt_i;
                s1_sign_r        <= sqrt_i ? 1'b0 : (fmod_i ? op_a_i[63] : qsign);
                s1_exp_a_r       <= $signed(14'(pycore_f64_exp_eff(op_a_i))) - $signed(14'(lz_a));
                s1_exp_b_r       <= $signed(14'(pycore_f64_exp_eff(op_b_i))) - $signed(14'(lz_b));
                s1_sig_a_r       <= sig_a << lz_a;
                s1_sig_b_r       <= sig_b << lz_b;
                s1_special_r     <= special;
                s1_special_val_r <= special_val;
                s1_a_r           <= op_a_i;
            end
            fin_r <= s1_valid_r && (s1_special_r || fmod_small);
            if (s1_valid_r) begin
                s2_fmod_r        <= s1_fmod_r;
                s2_sqrt_r        <= s1_sqrt_r;
                s2_sign_r        <= s1_sign_r;
                // DIV: ea - eb + 1023; SQRT: floor((ea - 1023) / 2) + 1023; FMOD: eb
                s2_exp_r         <= s1_sqrt_r ? (((s1_exp_a_r - 14'sd1023) >>> 1) + 14'sd1023) :
                                    (s1_fmod_r ? s1_exp_b_r : (d + 14'sd1023));
                s2_special_r     <= s1_special_r || fmod_small;
                s2_special_val_r <= s1_special_r ? s1_special_val_r : s1_a_r;
            end
        end
    end

    // ---------------- last cycle: normalize / round / pack ----------------
    logic signed [13:0] r_exp;
    logic [52:0]        r_sig;
    logic               r_g, r_r, r_s;
    logic [5:0]         rem_lz;

    always_comb begin
        rem_lz = pycore_clz53(rem[52:0]);
        if (s2_fmod_r) begin
            // Exact: the remainder (< b's significand) scaled by b's exponent.
            r_exp = s2_exp_r - $signed(14'(rem_lz));
            r_sig = rem[52:0] << rem_lz;
            r_g   = 1'b0;
            r_r   = 1'b0;
            r_s   = 1'b0;
        end else if (s2_sqrt_r) begin
            // Root in [2^(RB-1), 2^RB), RB = 56 (RL = 2) or 55 (RL = 1).
            r_exp = s2_exp_r;
            if (RL == 2) begin
                r_sig = quot[55:3];
                r_g   = quot[2];
                r_r   = quot[1];
                r_s   = quot[0] | (rem != '0);
            end else begin
                r_sig = quot[54:2];
                r_g   = quot[1];
                r_r   = quot[0];
                r_s   = (rem != '0);
            end
        end else if (quot[55]) begin
            r_exp = s2_exp_r;
            r_sig = quot[55:3];
            r_g   = quot[2];
            r_r   = quot[1];
            r_s   = quot[0] | (rem != '0);
        end else begin
            r_exp = s2_exp_r - 14'sd1;
            r_sig = quot[54:2];
            r_g   = quot[1];
            r_r   = quot[0];
            r_s   = (rem != '0);
        end
    end

    assign result_o = s2_special_r ? s2_special_val_r
                    : pycore_f64_pack_round(s2_sign_r, r_exp, r_sig, r_g, r_r, r_s);
    assign done_o   = core_done | fin_r;
    assign busy_o   = s1_valid_r | core_busy | core_done | fin_r;

endmodule
