`include "pycore_defs.svh"

// IEEE 754 binary64 add / subtract, round-to-nearest-even, full subnormal
// support.  Three register stages; the round / pack logic of the last
// stage drives result_o combinationally, so done_o comes 4 cycles after
// the accept cycle:
//
//   C0  unpack, order the operands by magnitude            -> stage 1 regs
//   C1  exponent difference, align with sticky, add / sub  -> stage 2 regs
//   C2  leading-zero normalize (bounded by the exponent)    -> stage 3 regs
//   C3  round-to-nearest-even, pack, specials               -> result_o
//
// Handshake: level start_i, one-cycle done_o, withdrawing start_i flushes
// the pipeline (see pycore_umul_seq.sv).  Only one operation is in flight;
// the valid bits are already per stage so the unit can be pipelined later
// by letting a new accept overlap the stages.
module pycore_fp_add (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic        sub_i,          // 1: a - b
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,
    output logic        done_o,
    output logic        busy_o
);

    // ---------------- stage 1: unpack / order ----------------
    logic        s1_valid_r;
    logic        s1_sign_big_r, s1_sign_small_r;
    logic [10:0] s1_exp_big_r, s1_exp_small_r;
    logic [52:0] s1_sig_big_r, s1_sig_small_r;
    logic        s1_special_r;          // result fully decided in C0
    logic [63:0] s1_special_val_r;

    logic        b_sign_eff;
    logic        a_bigger;
    logic        a_nan, b_nan, a_inf, b_inf;
    logic        special;
    logic [63:0] special_val;

    assign b_sign_eff = op_b_i[63] ^ sub_i;
    assign a_bigger   = (op_a_i[62:0] >= op_b_i[62:0]);
    assign a_nan = pycore_f64_is_nan(op_a_i);
    assign b_nan = pycore_f64_is_nan(op_b_i);
    assign a_inf = pycore_f64_is_inf(op_a_i);
    assign b_inf = pycore_f64_is_inf(op_b_i);

    always_comb begin
        special     = 1'b0;
        special_val = PY_F64_QNAN;
        if (a_nan || b_nan) begin
            special = 1'b1;
        end else if (a_inf && b_inf) begin
            special     = 1'b1;
            special_val = (op_a_i[63] == b_sign_eff) ? op_a_i : PY_F64_QNAN;
        end else if (a_inf) begin
            special     = 1'b1;
            special_val = op_a_i;
        end else if (b_inf) begin
            special     = 1'b1;
            special_val = {b_sign_eff, op_b_i[62:0]};
        end
    end

    // ---------------- stage 2: align + add ----------------
    logic        s2_valid_r;
    logic        s2_sign_r;              // sign of the larger magnitude
    logic        s2_both_neg_r;          // for the exact-zero sign rule
    logic [10:0] s2_exp_r;
    logic [56:0] s2_sum_r;
    logic        s2_special_r;
    logic [63:0] s2_special_val_r;

    logic [10:0] exp_diff;
    logic [55:0] ext_big, ext_small, aligned;
    logic [55:0] lost_mask;
    logic        sticky;
    logic [56:0] sum;

    assign exp_diff = s1_exp_big_r - s1_exp_small_r;
    assign ext_big   = {s1_sig_big_r, 3'b000};
    assign ext_small = {s1_sig_small_r, 3'b000};
    always_comb begin
        lost_mask = '0;
        sticky    = 1'b0;
        if (exp_diff > 11'd55) begin
            aligned = {55'd0, |ext_small};
        end else begin
            lost_mask = (56'd1 << exp_diff[5:0]) - 56'd1;
            sticky    = |(ext_small & lost_mask);
            aligned   = ext_small >> exp_diff[5:0];
            aligned[0] = aligned[0] | sticky;
        end
        if (s1_sign_big_r == s1_sign_small_r)
            sum = {1'b0, ext_big} + {1'b0, aligned};
        else
            sum = {1'b0, ext_big} - {1'b0, aligned};
    end

    // ---------------- stage 3: normalize ----------------
    logic        s3_valid_r;
    logic        s3_sign_r;
    logic signed [13:0] s3_exp_r;
    logic [52:0] s3_sig_r;
    logic        s3_g_r, s3_r_r, s3_s_r;
    logic        s3_special_r;
    logic [63:0] s3_special_val_r;

    logic [5:0]  lz;
    logic [5:0]  sh;
    logic [55:0] norm;
    logic        n_sign;
    logic signed [13:0] n_exp;
    logic [52:0] n_sig;
    logic        n_g, n_r, n_s;

    always_comb begin
        lz = pycore_clz56(s2_sum_r[55:0]);
        // Never shift past exponent 1: results below that are subnormal
        // and pack with a clear hidden bit.
        sh = (14'(lz) < (14'(s2_exp_r) - 14'd1)) ? lz : 6'(s2_exp_r - 11'd1);
        norm = s2_sum_r[55:0] << sh;
        n_sign = s2_sign_r;
        if (s2_sum_r[56]) begin
            n_exp = $signed(14'(s2_exp_r)) + 14'sd1;
            n_sig = s2_sum_r[56:4];
            n_g   = s2_sum_r[3];
            n_r   = s2_sum_r[2];
            n_s   = s2_sum_r[1] | s2_sum_r[0];
        end else begin
            n_exp = $signed(14'(s2_exp_r)) - $signed(14'(sh));
            n_sig = norm[55:3];
            n_g   = norm[2];
            n_r   = norm[1];
            n_s   = norm[0];
        end
        if (s2_sum_r == 57'd0) begin
            n_sign = s2_both_neg_r;       // (-0) + (-0) = -0; x - x = +0
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            s1_valid_r <= 1'b0; s2_valid_r <= 1'b0; s3_valid_r <= 1'b0;
            s1_sign_big_r <= 1'b0; s1_sign_small_r <= 1'b0;
            s1_exp_big_r <= '0; s1_exp_small_r <= '0;
            s1_sig_big_r <= '0; s1_sig_small_r <= '0;
            s1_special_r <= 1'b0; s1_special_val_r <= '0;
            s2_sign_r <= 1'b0; s2_both_neg_r <= 1'b0; s2_exp_r <= '0; s2_sum_r <= '0;
            s2_special_r <= 1'b0; s2_special_val_r <= '0;
            s3_sign_r <= 1'b0; s3_exp_r <= '0; s3_sig_r <= '0;
            s3_g_r <= 1'b0; s3_r_r <= 1'b0; s3_s_r <= 1'b0;
            s3_special_r <= 1'b0; s3_special_val_r <= '0;
        end else if (!start_i) begin
            s1_valid_r <= 1'b0;
            s2_valid_r <= 1'b0;
            s3_valid_r <= 1'b0;
        end else begin
            // C0: accept when nothing is in flight.
            s1_valid_r <= start_i && !busy_o;
            if (a_bigger) begin
                s1_sign_big_r   <= op_a_i[63];
                s1_sign_small_r <= b_sign_eff;
                s1_exp_big_r    <= pycore_f64_exp_eff(op_a_i);
                s1_exp_small_r  <= pycore_f64_exp_eff(op_b_i);
                s1_sig_big_r    <= pycore_f64_sig(op_a_i);
                s1_sig_small_r  <= pycore_f64_sig(op_b_i);
            end else begin
                s1_sign_big_r   <= b_sign_eff;
                s1_sign_small_r <= op_a_i[63];
                s1_exp_big_r    <= pycore_f64_exp_eff(op_b_i);
                s1_exp_small_r  <= pycore_f64_exp_eff(op_a_i);
                s1_sig_big_r    <= pycore_f64_sig(op_b_i);
                s1_sig_small_r  <= pycore_f64_sig(op_a_i);
            end
            s1_special_r     <= special;
            s1_special_val_r <= special_val;

            // C1
            s2_valid_r       <= s1_valid_r;
            s2_sign_r        <= s1_sign_big_r;
            s2_both_neg_r    <= s1_sign_big_r & s1_sign_small_r;
            s2_exp_r         <= s1_exp_big_r;
            s2_sum_r         <= sum;
            s2_special_r     <= s1_special_r;
            s2_special_val_r <= s1_special_val_r;

            // C2
            s3_valid_r       <= s2_valid_r;
            s3_sign_r        <= n_sign;
            s3_exp_r         <= n_exp;
            s3_sig_r         <= n_sig;
            s3_g_r           <= n_g;
            s3_r_r           <= n_r;
            s3_s_r           <= n_s;
            s3_special_r     <= s2_special_r;
            s3_special_val_r <= s2_special_val_r;
        end
    end

    // C3: round / pack.
    assign result_o = s3_special_r ? s3_special_val_r
                    : pycore_f64_pack_round(s3_sign_r, s3_exp_r, s3_sig_r,
                                            s3_g_r, s3_r_r, s3_s_r);
    assign done_o   = s3_valid_r;
    assign busy_o   = s1_valid_r | s2_valid_r | s3_valid_r;

endmodule
