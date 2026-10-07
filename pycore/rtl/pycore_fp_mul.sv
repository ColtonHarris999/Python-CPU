`include "pycore_defs.svh"

// IEEE 754 binary64 multiply, round-to-nearest-even, full subnormal
// support.  The 53 x 53 significand product comes from an iterative
// pycore_umul_seq (STEP multiplier bits per clock) that the parent owns
// and shares with pycore_fp_pow (mul_*_o / mul_*_i below; the two never
// run at the same time), so the per-cycle datapath is one 53 x STEP
// multiply-accumulate:
//
//   C0            unpack, normalize subnormal significands  -> stage 1 regs
//   C1 .. C(N)    N = ceil(53/STEP) product steps (4 at STEP = 14)
//   C(N+1)        product registered by the multiplier core;
//                 normalize by one bit, round, pack          -> result_o
//
// done_o is asserted in C(N+1): the 6th cycle counting the accept cycle as
// the first, at the default STEP.
// Handshake as in pycore_umul_seq.sv (level start_i, one-cycle done_o,
// withdrawing start_i aborts).
module pycore_fp_mul (
    input  logic         clk_i,
    input  logic         rst_n_i,
    input  logic         start_i,
    input  logic [63:0]  op_a_i,
    input  logic [63:0]  op_b_i,
    output logic [63:0]  result_o,
    output logic         done_o,
    output logic         busy_o,
    // Shared significand multiplier (pycore_umul_seq, BW = 53): request,
    // operands, and its product / handshake back.
    output logic         mul_start_o,
    output logic [52:0]  mul_a_o,
    output logic [52:0]  mul_b_o,
    input  logic [105:0] mul_product_i,
    input  logic         mul_done_i,
    input  logic         mul_busy_i
);

    // ---------------- C0: unpack / normalize ----------------
    logic               s1_valid_r;
    logic               s1_sign_r;
    logic signed [13:0] s1_exp_r;        // ea + eb - 1023 (normalized sigs)
    logic [52:0]        s1_sig_a_r, s1_sig_b_r;
    logic               s1_special_r;
    logic [63:0]        s1_special_val_r;

    logic [52:0] sig_a, sig_b, sig_a_n, sig_b_n;
    logic [5:0]  lz_a, lz_b;
    logic signed [13:0] exp_a_n, exp_b_n;
    logic        a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
    logic        sign;
    logic        special;
    logic [63:0] special_val;

    assign sig_a = pycore_f64_sig(op_a_i);
    assign sig_b = pycore_f64_sig(op_b_i);
    assign lz_a  = pycore_clz53(sig_a);
    assign lz_b  = pycore_clz53(sig_b);
    assign sig_a_n = sig_a << lz_a;
    assign sig_b_n = sig_b << lz_b;
    assign exp_a_n = $signed(14'(pycore_f64_exp_eff(op_a_i))) - $signed(14'(lz_a));
    assign exp_b_n = $signed(14'(pycore_f64_exp_eff(op_b_i))) - $signed(14'(lz_b));
    assign a_nan  = pycore_f64_is_nan(op_a_i);
    assign b_nan  = pycore_f64_is_nan(op_b_i);
    assign a_inf  = pycore_f64_is_inf(op_a_i);
    assign b_inf  = pycore_f64_is_inf(op_b_i);
    assign a_zero = pycore_f64_is_zero(op_a_i);
    assign b_zero = pycore_f64_is_zero(op_b_i);
    assign sign   = op_a_i[63] ^ op_b_i[63];

    always_comb begin
        special     = 1'b0;
        special_val = PY_F64_QNAN;
        if (a_nan || b_nan) begin
            special = 1'b1;
        end else if (a_inf || b_inf) begin
            special     = 1'b1;
            special_val = (a_zero || b_zero) ? PY_F64_QNAN : {sign, PY_F64_PINF[62:0]};
        end else if (a_zero || b_zero) begin
            special     = 1'b1;
            special_val = {sign, 63'd0};
        end
    end

    // ---------------- C1..: significand product ----------------
    logic [105:0] product;
    logic         mul_done;
    logic         mul_busy;

    // Keep start high while the core runs; a flush drops it too.
    assign mul_start_o = start_i && (s1_valid_r || mul_busy);
    assign mul_a_o     = s1_sig_a_r;
    assign mul_b_o     = s1_sig_b_r;
    assign product     = mul_product_i;
    assign mul_done    = mul_done_i;
    assign mul_busy    = mul_busy_i;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            s1_valid_r       <= 1'b0;
            s1_sign_r        <= 1'b0;
            s1_exp_r         <= '0;
            s1_sig_a_r       <= '0;
            s1_sig_b_r       <= '0;
            s1_special_r     <= 1'b0;
            s1_special_val_r <= '0;
        end else if (!start_i) begin
            s1_valid_r <= 1'b0;
        end else begin
            s1_valid_r <= start_i && !busy_o;
            if (start_i && !busy_o) begin
                s1_sign_r        <= sign;
                s1_exp_r         <= exp_a_n + exp_b_n - 14'sd1023;
                s1_sig_a_r       <= sig_a_n;
                s1_sig_b_r       <= sig_b_n;
                s1_special_r     <= special;
                s1_special_val_r <= special_val;
            end
        end
    end

    // ---------------- last cycle: normalize / round / pack ----------------
    logic signed [13:0] r_exp;
    logic [52:0]        r_sig;
    logic               r_g, r_r, r_s;

    always_comb begin
        if (product[105]) begin
            r_exp = s1_exp_r + 14'sd1;
            r_sig = product[105:53];
            r_g   = product[52];
            r_r   = product[51];
            r_s   = |product[50:0];
        end else begin
            r_exp = s1_exp_r;
            r_sig = product[104:52];
            r_g   = product[51];
            r_r   = product[50];
            r_s   = |product[49:0];
        end
    end

    assign result_o = s1_special_r ? s1_special_val_r
                    : pycore_f64_pack_round(s1_sign_r, r_exp, r_sig, r_g, r_r, r_s);
    assign done_o   = mul_done;
    assign busy_o   = s1_valid_r | mul_busy | mul_done;

endmodule
