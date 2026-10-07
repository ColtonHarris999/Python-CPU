`include "pycore_defs.svh"

// Binary64 floating-point unit for the execute fabric.
//
// Three hardware pipelines do the real arithmetic -- pycore_fp_add
// (add / subtract), pycore_fp_mul and pycore_fp_divrem (divide, fmod) --
// and a small sequencer composes everything else out of them exactly the
// way CPython does in floatobject.c / complexobject.c, so the results are
// bit-identical to the host for every operation that is a fixed sequence
// of IEEE operations:
//
//   ADD SUB MUL TRUE_DIV   one pipeline pass (pass-through, no extra cycle)
//   MOD                    fmod, then the sign fix-up add        (float_rem)
//   FLOOR_DIV              fmod, sub, div, fix-ups, floor        (float_divmod)
//   POWER                  CPython's special cases, then square-and-multiply
//                          on an integer-valued exponent (see docs/alu.md
//                          for the deviations from libm pow())
//   NEG POS NOT EQ..GE     combinational, 1 cycle
//   complex ADD SUB MUL    per-component sequences (_Py_c_sum/_diff/_prod)
//   complex TRUE_DIV       Smith's algorithm as in _Py_c_quot
//   complex EQ NE NEG NOT  combinational, 1 cycle
//
// exception_o replaces done_o when the operation ends in a Python
// exception: ZeroDivisionError (x / 0.0, x // 0.0, x % 0.0, 0.0 ** -y,
// z / 0j), OverflowError (finite ** finite overflowing to inf), and the
// two power cases the hardware does not implement (fractional exponent,
// negative base with a fractional exponent, which is a complex result in
// Python).  Division by zero is reported in the accept cycle, before any
// pipeline starts.
//
// Operands are binary64 bit patterns already promoted by pycore_promote;
// complex operands carry the imaginary part in [127:64].  Handshake:
// level start_i, one-cycle done_o / exception_o, stall_o = start_i and
// neither; withdrawing start_i aborts (see pycore_umul_seq.sv).
module pycore_fpu #(
    parameter int MUL_STEP = 14,
    parameter int DIV_RL   = 2
) (
    input  logic         clk_i,
    input  logic         rst_n_i,
    input  logic         start_i,
    input  logic [4:0]   op_i,
    input  logic         complex_i,
    input  logic [127:0] op_a_i,
    input  logic [127:0] op_b_i,
    output logic [127:0] result_o,
    output logic         exception_o,
    output logic         done_o,
    output logic         stall_o,
    output logic         busy_o
);

    // ---------------------------------------------------------------------
    // Primitive pipelines and the shared issue bus
    // ---------------------------------------------------------------------
    logic        u_add_start, u_sub, u_mul_start, u_div_start, u_fmod;
    logic [63:0] u_a, u_b;
    logic [63:0] add_res, mul_res, div_res;
    logic        add_done, mul_done, div_done;
    logic        add_busy, mul_busy, div_busy;
    logic        u_done;
    logic [63:0] u_res;

    pycore_fp_add u_add (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .start_i(u_add_start), .sub_i(u_sub),
        .op_a_i(u_a), .op_b_i(u_b),
        .result_o(add_res), .done_o(add_done), .busy_o(add_busy)
    );

    pycore_fp_mul #(.STEP(MUL_STEP)) u_mul (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .start_i(u_mul_start),
        .op_a_i(u_a), .op_b_i(u_b),
        .result_o(mul_res), .done_o(mul_done), .busy_o(mul_busy)
    );

    pycore_fp_divrem #(.RL(DIV_RL)) u_div (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .start_i(u_div_start), .fmod_i(u_fmod),
        .op_a_i(u_a), .op_b_i(u_b),
        .result_o(div_res), .done_o(div_done), .busy_o(div_busy)
    );

    assign u_done = add_done | mul_done | div_done;
    assign u_res  = add_done ? add_res : (mul_done ? mul_res : div_res);

    // ---------------------------------------------------------------------
    // Sequencer state
    // ---------------------------------------------------------------------
    typedef enum logic [5:0] {
        S_IDLE,
        S_DIRECT,                       // scalar add/sub/mul/div pass-through
        S_MOD_FMOD, S_MOD_FIX, S_MOD_ADD,
        S_FD_FMOD, S_FD_SUB, S_FD_DIV, S_FD_FIX, S_FD_SUB1,
        S_FD_FLOOR, S_FD_DIFF, S_FD_HALF, S_FD_ADD1,
        S_POW_NORM, S_POW_STEP, S_POW_SQR, S_POW_MUL, S_POW_FIN, S_POW_RECIP, S_POW_INV,
        S_POW_END,
        S_CADD_R, S_CADD_I,
        S_CMUL_1, S_CMUL_2, S_CMUL_3, S_CMUL_4, S_CMUL_5, S_CMUL_6,
        S_CDIV_1, S_CDIV_2, S_CDIV_3, S_CDIV_4, S_CDIV_5,
        S_CDIV_6, S_CDIV_7, S_CDIV_8, S_CDIV_9,
        S_DONE, S_EXC
    } state_e;

    state_e       state_r;
    logic [63:0]  t0_r, t1_r, t2_r, t3_r;
    logic [63:0]  pow_n_r;                // exponent bits below the MSB, MSB first
    logic [63:0]  pow_n0_r;               // |exponent| as accepted (for the retry)
    logic [6:0]   pow_cnt_r;              // how many of them remain
    logic         pow_neg_r, pow_recip_r;
    logic         cdiv_b_r;               // Smith's algorithm, |bi| > |br| path
    logic [127:0] res_r;

    // Operand shorthands.
    logic [63:0] ar, ai, br, bi;
    assign ar = op_a_i[63:0];
    assign ai = op_a_i[127:64];
    assign br = op_b_i[63:0];
    assign bi = op_b_i[127:64];

    // ---------------------------------------------------------------------
    // Accept-cycle decode (state S_IDLE)
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] { K_COMB, K_EXC, K_DIRECT, K_SEQ } kind_e;

    kind_e        dec_kind;
    logic [127:0] dec_result;
    state_e       dec_next;
    logic         dec_sub;                // DIRECT: subtract
    logic         dec_div;                // DIRECT: divide (else add/mul)
    logic         dec_mul;
    logic         dec_cdiv_b;
    logic         dec_pow_neg, dec_pow_recip;
    logic [63:0]  dec_pow_n;

    logic        a_nan, b_nan, a_inf, b_inf, a_zero, b_zero, b_int;
    logic        a_abs_one, a_abs_gt_one;
    logic        b_odd, b_gt0, b_lt0;
    logic [63:0] a_abs, b_trunc_int;
    logic        b_trunc_ok;
    logic [63:0] br_abs, bi_abs;
    logic [3:0]  cmp_rb;                   // |br| vs |bi|

    assign a_nan  = pycore_f64_is_nan(ar);
    assign b_nan  = pycore_f64_is_nan(br);
    assign a_inf  = pycore_f64_is_inf(ar);
    assign b_inf  = pycore_f64_is_inf(br);
    assign a_zero = pycore_f64_is_zero(ar);
    assign b_zero = pycore_f64_is_zero(br);
    assign a_abs  = {1'b0, ar[62:0]};
    assign a_abs_one    = (a_abs == PY_F64_ONE);
    assign a_abs_gt_one = pycore_f64_gt(a_abs, PY_F64_ONE);
    assign b_int  = pycore_f64_is_finite(br) && (pycore_f64_floor(br) == br);
    assign b_odd  = pycore_f64_is_odd_integer(br);
    assign b_gt0  = pycore_f64_gt(br, PY_F64_PZERO);
    assign b_lt0  = pycore_f64_lt_zero(br);
    assign br_abs = {1'b0, br[62:0]};
    assign bi_abs = {1'b0, bi[62:0]};
    assign cmp_rb = pycore_f64_cmp(br_abs, bi_abs);

    always_comb begin
        b_trunc_ok = pycore_float_trunc_int64({64'd0, br}, b_trunc_int);
    end

    always_comb begin
        dec_kind      = K_EXC;
        dec_result    = '0;
        dec_next      = S_IDLE;
        dec_sub       = 1'b0;
        dec_div       = 1'b0;
        dec_mul       = 1'b0;
        dec_cdiv_b    = 1'b0;
        dec_pow_neg   = 1'b0;
        dec_pow_recip = 1'b0;
        dec_pow_n     = '0;

        if (!complex_i) begin
            unique case (op_i)
                PY_ALU_ADD: begin dec_kind = K_DIRECT; end
                PY_ALU_SUB: begin dec_kind = K_DIRECT; dec_sub = 1'b1; end
                PY_ALU_MUL: begin dec_kind = K_DIRECT; dec_mul = 1'b1; end
                PY_ALU_TRUE_DIV: begin
                    dec_kind = b_zero ? K_EXC : K_DIRECT;
                    dec_div  = 1'b1;
                end
                PY_ALU_MOD: begin
                    dec_kind = b_zero ? K_EXC : K_SEQ;
                    dec_next = S_MOD_FMOD;
                end
                PY_ALU_FLOOR_DIV: begin
                    dec_kind = b_zero ? K_EXC : K_SEQ;
                    dec_next = S_FD_FMOD;
                end
                PY_ALU_POWER: begin
                    // CPython float_pow(), special cases first.
                    dec_kind = K_COMB;
                    if (b_zero) begin
                        dec_result = {64'd0, PY_F64_ONE};
                    end else if (a_nan) begin
                        dec_result = {64'd0, ar};
                    end else if (b_nan) begin
                        dec_result = {64'd0, (ar == PY_F64_ONE) ? PY_F64_ONE : br};
                    end else if (b_inf) begin
                        if (a_abs_one)                     dec_result = {64'd0, PY_F64_ONE};
                        else if (b_gt0 == a_abs_gt_one)    dec_result = {64'd0, PY_F64_PINF};
                        else                               dec_result = {64'd0, PY_F64_PZERO};
                    end else if (a_inf) begin
                        if (b_gt0) dec_result = {64'd0, b_odd ? ar : a_abs};
                        else       dec_result = {64'd0, b_odd ? {ar[63], 63'd0} : PY_F64_PZERO};
                    end else if (a_zero) begin
                        if (b_lt0) dec_kind = K_EXC;                 // ZeroDivisionError
                        else       dec_result = {64'd0, b_odd ? ar : PY_F64_PZERO};
                    end else if (!b_int || !b_trunc_ok) begin
                        dec_kind = K_EXC;   // fractional / huge exponent: not in hardware
                    end else if (a_abs_one) begin
                        dec_result = {64'd0, (ar[63] && b_odd) ? PY_F64_NONE : PY_F64_ONE};
                    end else begin
                        dec_kind      = K_SEQ;
                        dec_next      = S_POW_NORM;
                        dec_pow_neg   = ar[63] && b_odd;
                        dec_pow_recip = b_lt0;
                        dec_pow_n     = b_trunc_int[63] ? (~b_trunc_int + 64'd1) : b_trunc_int;
                    end
                end
                PY_ALU_NEG: begin
                    dec_kind   = K_COMB;
                    dec_result = {64'd0, ~ar[63], ar[62:0]};
                end
                PY_ALU_POS, PY_ALU_PASS: begin
                    dec_kind   = K_COMB;
                    dec_result = {64'd0, ar};
                end
                PY_ALU_NOT: begin
                    dec_kind   = K_COMB;
                    dec_result = {127'd0, a_zero};
                end
                PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_LE, PY_ALU_GT, PY_ALU_GE: begin
                    dec_kind   = K_COMB;
                    dec_result = {127'd0, pycore_f64_compare_op(op_i, ar, br)};
                end
                default: begin
                    dec_kind = K_EXC;
                end
            endcase
        end else begin
            unique case (op_i)
                PY_ALU_ADD: begin dec_kind = K_SEQ; dec_next = S_CADD_R; end
                PY_ALU_SUB: begin dec_kind = K_SEQ; dec_next = S_CADD_R; dec_sub = 1'b1; end
                PY_ALU_MUL: begin dec_kind = K_SEQ; dec_next = S_CMUL_1; end
                PY_ALU_TRUE_DIV: begin
                    // _Py_c_quot: scale by the larger component.
                    if (cmp_rb[2] || cmp_rb[1]) begin          // |br| >= |bi|
                        dec_kind   = (br_abs == 64'd0) ? K_EXC : K_SEQ;
                        dec_next   = S_CDIV_1;
                    end else if (cmp_rb[0]) begin               // |bi| > |br|
                        dec_kind   = K_SEQ;
                        dec_next   = S_CDIV_1;
                        dec_cdiv_b = 1'b1;
                    end else begin                              // a NaN component
                        dec_kind   = K_COMB;
                        dec_result = {PY_F64_QNAN, PY_F64_QNAN};
                    end
                end
                PY_ALU_NEG: begin
                    dec_kind   = K_COMB;
                    dec_result = {~ai[63], ai[62:0], ~ar[63], ar[62:0]};
                end
                PY_ALU_POS, PY_ALU_PASS: begin
                    dec_kind   = K_COMB;
                    dec_result = op_a_i;
                end
                PY_ALU_NOT: begin
                    dec_kind   = K_COMB;
                    dec_result = {127'd0, pycore_f64_is_zero(ar) && pycore_f64_is_zero(ai)};
                end
                PY_ALU_EQ: begin
                    dec_kind   = K_COMB;
                    dec_result = {127'd0, pycore_f64_eq(ar, br) && pycore_f64_eq(ai, bi)};
                end
                PY_ALU_NE: begin
                    dec_kind   = K_COMB;
                    dec_result = {127'd0, !(pycore_f64_eq(ar, br) && pycore_f64_eq(ai, bi))};
                end
                default: begin
                    dec_kind = K_EXC;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Issue logic: which primitive runs in the current state, on what
    // ---------------------------------------------------------------------
    // Complex-division operand roles (Smith's algorithm, both scalings).
    //   path A (|br| >= |bi|): ratio = bi/br, denom = br + bi*ratio,
    //      rr = (ar + ai*ratio)/denom, ri = (ai - ar*ratio)/denom
    //   path B (|bi| >  |br|): ratio = br/bi, denom = br*ratio + bi,
    //      rr = (ar*ratio + ai)/denom, ri = (ai*ratio - ar)/denom
    always_comb begin
        u_add_start = 1'b0;
        u_sub       = 1'b0;
        u_mul_start = 1'b0;
        u_div_start = 1'b0;
        u_fmod      = 1'b0;
        u_a         = ar;
        u_b         = br;

        unique case (state_r)
            S_IDLE: begin
                // Scalar add/sub/mul/div start in the accept cycle itself.
                if (start_i && dec_kind == K_DIRECT) begin
                    u_add_start = !dec_mul && !dec_div;
                    u_sub       = dec_sub;
                    u_mul_start = dec_mul;
                    u_div_start = dec_div;
                end
            end
            S_DIRECT: begin
                u_add_start = add_busy;
                u_sub       = (op_i == PY_ALU_SUB);
                u_mul_start = mul_busy;
                u_div_start = div_busy;
            end

            // ---- float % ----
            S_MOD_FMOD: begin u_div_start = 1'b1; u_fmod = 1'b1; end
            S_MOD_ADD:  begin u_add_start = 1'b1; u_a = t0_r; u_b = br; end

            // ---- float // ----
            S_FD_FMOD:  begin u_div_start = 1'b1; u_fmod = 1'b1; end
            S_FD_SUB:   begin u_add_start = 1'b1; u_sub = 1'b1; u_a = ar; u_b = t0_r; end
            S_FD_DIV:   begin u_div_start = 1'b1; u_a = t1_r; u_b = br; end
            S_FD_SUB1:  begin u_add_start = 1'b1; u_sub = 1'b1; u_a = t1_r; u_b = PY_F64_ONE; end
            S_FD_DIFF:  begin u_add_start = 1'b1; u_sub = 1'b1; u_a = t1_r; u_b = t2_r; end
            S_FD_ADD1:  begin u_add_start = 1'b1; u_a = t2_r; u_b = PY_F64_ONE; end

            // ---- float ** (t0 = acc, t1 = base) ----
            S_POW_SQR:   begin u_mul_start = 1'b1; u_a = t0_r; u_b = t0_r; end
            S_POW_MUL:   begin u_mul_start = 1'b1; u_a = t0_r; u_b = t1_r; end
            S_POW_RECIP: begin u_div_start = 1'b1; u_a = PY_F64_ONE; u_b = t0_r; end
            S_POW_INV:   begin u_div_start = 1'b1; u_a = PY_F64_ONE; u_b = t1_r; end

            // ---- complex + / - ----
            S_CADD_R: begin u_add_start = 1'b1; u_sub = (op_i == PY_ALU_SUB); u_a = ar; u_b = br; end
            S_CADD_I: begin u_add_start = 1'b1; u_sub = (op_i == PY_ALU_SUB); u_a = ai; u_b = bi; end

            // ---- complex * ----
            S_CMUL_1: begin u_mul_start = 1'b1; u_a = ar; u_b = br; end
            S_CMUL_2: begin u_mul_start = 1'b1; u_a = ai; u_b = bi; end
            S_CMUL_3: begin u_mul_start = 1'b1; u_a = ar; u_b = bi; end
            S_CMUL_4: begin u_mul_start = 1'b1; u_a = ai; u_b = br; end
            S_CMUL_5: begin u_add_start = 1'b1; u_sub = 1'b1; u_a = t0_r; u_b = t1_r; end
            S_CMUL_6: begin u_add_start = 1'b1; u_a = t2_r; u_b = t3_r; end

            // ---- complex / ----
            S_CDIV_1: begin
                u_div_start = 1'b1;
                u_a = cdiv_b_r ? br : bi;  u_b = cdiv_b_r ? bi : br;      // ratio
            end
            S_CDIV_2: begin
                u_mul_start = 1'b1;
                u_a = cdiv_b_r ? br : bi;  u_b = t0_r;
            end
            S_CDIV_3: begin
                u_add_start = 1'b1;                                       // denom
                u_a = cdiv_b_r ? t1_r : br;  u_b = cdiv_b_r ? bi : t1_r;
            end
            S_CDIV_4: begin
                u_mul_start = 1'b1;
                u_a = cdiv_b_r ? ar : ai;  u_b = t0_r;
            end
            S_CDIV_5: begin
                u_add_start = 1'b1;
                u_a = cdiv_b_r ? t2_r : ar;  u_b = cdiv_b_r ? ai : t2_r;
            end
            S_CDIV_6: begin u_div_start = 1'b1; u_a = t2_r; u_b = t1_r; end   // rr
            S_CDIV_7: begin
                u_mul_start = 1'b1;
                u_a = cdiv_b_r ? ai : ar;  u_b = t0_r;
            end
            S_CDIV_8: begin
                u_add_start = 1'b1; u_sub = 1'b1;
                u_a = cdiv_b_r ? t3_r : ai;  u_b = cdiv_b_r ? ar : t3_r;
            end
            S_CDIV_9: begin u_div_start = 1'b1; u_a = t3_r; u_b = t1_r; end   // ri

            default: ;
        endcase
    end

    // ---------------------------------------------------------------------
    // Sequencer
    // ---------------------------------------------------------------------
    logic        mod_fix_add;             // (b < 0) != (mod < 0), mod != 0
    logic        fd_div_nonzero;
    logic        fd_half_up;
    logic [63:0] fd_floor;
    logic        pow_overflow;
    logic [6:0]  pow_lz;

    assign mod_fix_add    = !pycore_f64_eq(t0_r, PY_F64_PZERO) &&
                            (b_lt0 != pycore_f64_lt_zero(t0_r));
    assign fd_div_nonzero = !pycore_f64_eq(t1_r, PY_F64_PZERO);
    assign fd_floor       = pycore_f64_floor(t1_r);
    assign fd_half_up     = pycore_f64_gt(t3_r, PY_F64_HALF);
    assign pow_overflow   = pycore_f64_is_inf(t0_r);
    assign pow_lz         = pycore_clz64(pow_n_r);

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r     <= S_IDLE;
            t0_r <= '0; t1_r <= '0; t2_r <= '0; t3_r <= '0;
            pow_n_r     <= '0;
            pow_n0_r    <= '0;
            pow_cnt_r   <= '0;
            pow_neg_r   <= 1'b0;
            pow_recip_r <= 1'b0;
            cdiv_b_r    <= 1'b0;
            res_r       <= '0;
        end else if (!start_i) begin
            state_r <= S_IDLE;
        end else begin
            unique case (state_r)
                S_IDLE: begin
                    if (dec_kind == K_DIRECT) begin
                        state_r <= S_DIRECT;
                    end else if (dec_kind == K_SEQ) begin
                        state_r     <= dec_next;
                        cdiv_b_r    <= dec_cdiv_b;
                        pow_neg_r   <= dec_pow_neg;
                        pow_recip_r <= dec_pow_recip;
                        pow_n_r     <= dec_pow_n;
                        pow_n0_r    <= dec_pow_n;
                        t0_r        <= PY_F64_ONE;        // pow accumulator
                        t1_r        <= a_abs;             // pow base
                    end
                    // K_COMB / K_EXC complete in this cycle.
                end
                S_DIRECT: begin
                    if (u_done) state_r <= S_IDLE;
                end

                // ---- float % : CPython float_rem ----
                S_MOD_FMOD: if (u_done) begin t0_r <= u_res; state_r <= S_MOD_FIX; end
                S_MOD_FIX: begin
                    if (mod_fix_add) begin
                        state_r <= S_MOD_ADD;
                    end else begin
                        res_r   <= {64'd0, pycore_f64_eq(t0_r, PY_F64_PZERO)
                                           ? {br[63], 63'd0} : t0_r};
                        state_r <= S_DONE;
                    end
                end
                S_MOD_ADD: if (u_done) begin res_r <= {64'd0, u_res}; state_r <= S_DONE; end

                // ---- float // : CPython float_divmod ----
                S_FD_FMOD: if (u_done) begin t0_r <= u_res; state_r <= S_FD_SUB; end
                S_FD_SUB:  if (u_done) begin t1_r <= u_res; state_r <= S_FD_DIV; end
                S_FD_DIV:  if (u_done) begin t1_r <= u_res; state_r <= S_FD_FIX; end
                S_FD_FIX:  state_r <= mod_fix_add ? S_FD_SUB1 : S_FD_FLOOR;
                S_FD_SUB1: if (u_done) begin t1_r <= u_res; state_r <= S_FD_FLOOR; end
                S_FD_FLOOR: begin
                    if (fd_div_nonzero) begin
                        t2_r    <= fd_floor;
                        state_r <= S_FD_DIFF;
                    end else begin
                        res_r   <= {64'd0, ar[63] ^ br[63], 63'd0};
                        state_r <= S_DONE;
                    end
                end
                S_FD_DIFF: if (u_done) begin t3_r <= u_res; state_r <= S_FD_HALF; end
                S_FD_HALF: begin
                    if (fd_half_up) begin
                        state_r <= S_FD_ADD1;
                    end else begin
                        res_r   <= {64'd0, t2_r};
                        state_r <= S_DONE;
                    end
                end
                S_FD_ADD1: if (u_done) begin res_r <= {64'd0, u_res}; state_r <= S_DONE; end

                // ---- float ** : MSB-first square-and-multiply ----
                S_POW_NORM: begin
                    // acc = base; the exponent's leading one is consumed by
                    // that, the remaining bits are walked high to low.
                    t0_r      <= t1_r;
                    pow_n_r   <= pow_n_r << (pow_lz + 7'd1);
                    pow_cnt_r <= 7'd63 - pow_lz;
                    state_r   <= S_POW_STEP;
                end
                S_POW_STEP: state_r <= (pow_cnt_r == 7'd0) ? S_POW_FIN : S_POW_SQR;
                S_POW_SQR: if (u_done) begin
                    t0_r <= u_res;
                    if (pow_n_r[63]) begin
                        state_r <= S_POW_MUL;
                    end else begin
                        pow_n_r   <= pow_n_r << 1;
                        pow_cnt_r <= pow_cnt_r - 7'd1;
                        state_r   <= S_POW_STEP;
                    end
                end
                S_POW_MUL: if (u_done) begin
                    t0_r      <= u_res;
                    pow_n_r   <= pow_n_r << 1;
                    pow_cnt_r <= pow_cnt_r - 7'd1;
                    state_r   <= S_POW_STEP;
                end
                S_POW_FIN: begin
                    // x ** -n: 1 / x**n, unless x**n overflowed -- then the
                    // true result is tiny or subnormal and is recomputed as
                    // (1/|x|) ** n, which cannot overflow (|x| > 1 here).
                    if (!pow_recip_r)      state_r <= S_POW_END;
                    else if (pow_overflow) state_r <= S_POW_INV;
                    else                   state_r <= S_POW_RECIP;
                end
                S_POW_RECIP: if (u_done) begin t0_r <= u_res; state_r <= S_POW_END; end
                S_POW_INV: if (u_done) begin
                    t1_r        <= u_res;
                    pow_n_r     <= pow_n0_r;
                    pow_recip_r <= 1'b0;
                    state_r     <= S_POW_NORM;
                end
                S_POW_END: begin
                    if (pow_overflow) begin
                        state_r <= S_EXC;                 // OverflowError
                    end else begin
                        res_r   <= {64'd0, t0_r[63] ^ pow_neg_r, t0_r[62:0]};
                        state_r <= S_DONE;
                    end
                end

                // ---- complex + - ----
                S_CADD_R: if (u_done) begin t0_r <= u_res; state_r <= S_CADD_I; end
                S_CADD_I: if (u_done) begin res_r <= {u_res, t0_r}; state_r <= S_DONE; end

                // ---- complex * ----
                S_CMUL_1: if (u_done) begin t0_r <= u_res; state_r <= S_CMUL_2; end
                S_CMUL_2: if (u_done) begin t1_r <= u_res; state_r <= S_CMUL_3; end
                S_CMUL_3: if (u_done) begin t2_r <= u_res; state_r <= S_CMUL_4; end
                S_CMUL_4: if (u_done) begin t3_r <= u_res; state_r <= S_CMUL_5; end
                S_CMUL_5: if (u_done) begin t0_r <= u_res; state_r <= S_CMUL_6; end
                S_CMUL_6: if (u_done) begin res_r <= {u_res, t0_r}; state_r <= S_DONE; end

                // ---- complex / ----
                S_CDIV_1: if (u_done) begin t0_r <= u_res; state_r <= S_CDIV_2; end
                S_CDIV_2: if (u_done) begin t1_r <= u_res; state_r <= S_CDIV_3; end
                S_CDIV_3: if (u_done) begin t1_r <= u_res; state_r <= S_CDIV_4; end
                S_CDIV_4: if (u_done) begin t2_r <= u_res; state_r <= S_CDIV_5; end
                S_CDIV_5: if (u_done) begin t2_r <= u_res; state_r <= S_CDIV_6; end
                S_CDIV_6: if (u_done) begin t2_r <= u_res; state_r <= S_CDIV_7; end
                S_CDIV_7: if (u_done) begin t3_r <= u_res; state_r <= S_CDIV_8; end
                S_CDIV_8: if (u_done) begin t3_r <= u_res; state_r <= S_CDIV_9; end
                S_CDIV_9: if (u_done) begin res_r <= {u_res, t2_r}; state_r <= S_DONE; end

                S_DONE, S_EXC: state_r <= S_IDLE;
                default:       state_r <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Outputs
    // ---------------------------------------------------------------------
    always_comb begin
        result_o    = res_r;
        done_o      = 1'b0;
        exception_o = 1'b0;
        unique case (state_r)
            S_IDLE: begin
                if (start_i) begin
                    unique case (dec_kind)
                        K_COMB: begin done_o = 1'b1; result_o = dec_result; end
                        K_EXC:  exception_o = 1'b1;
                        default: ;
                    endcase
                end
            end
            S_DIRECT: begin
                done_o   = u_done;
                result_o = {64'd0, u_res};
            end
            S_DONE: done_o = 1'b1;
            S_EXC:  exception_o = 1'b1;
            default: ;
        endcase
    end

    assign stall_o = start_i && !done_o && !exception_o;
    assign busy_o  = (state_r != S_IDLE);

endmodule
