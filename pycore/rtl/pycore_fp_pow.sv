`include "pycore_defs.svh"
`include "pycore_fp_pow_rom.svh"

// Binary64 power unit:  result = x ** y  for x > 0 finite (x != 1) and
// y finite non-zero, evaluated as 2 ** (y * log2 x).
//
// Both transcendental steps are shift-and-add digit recurrences over one
// FW-bit fixed-point datapath, so the per-cycle hardware is two barrel
// shifters and two adders; the only multiplier forms y * log2(x).
//
//   log2  x = m' * 2^E with m' in [2/3, 4/3).  Signed-digit multiplicative
//         normalisation  m' * prod(1 + d_j 2^-j) -> 1,  d_j in {-1, 0, +1}
//         chosen from the scaled residual w_j = 2^j (1 - x_j), |w_j| <= 4/3.
//         log2 m' = -sum d_j log2(1 + d_j 2^-j), read from the ROM.  The
//         digits are zero while 2^j |m'-1| < 1/2, so the recurrence starts
//         at j0 = max(2, s) with |m'-1| in [2^-(s+1), 2^-s), and both the
//         residual and the accumulator are kept scaled by 2^j0: log2 of an
//         x next to 1 keeps full relative precision, which y * log2 x
//         needs when y is huge.  NLOG digits leave a relative error
//         below 2^-(NLOG-2).
//   mul   L = E + log2 m' is normalised to LMW bits and multiplied by the
//         53-bit significand of y (pycore_umul_seq).  The product is
//         aligned to FP fraction bits: |P| >= 2^11 is an overflow or an
//         underflow to zero, otherwise P = I + F with F in [0, 1).
//   exp2  Restoring recurrence on F with the constants log2(1 + 2^-k):
//         whenever F >= log2(1 + 2^-k), subtract it and Z += Z 2^-k.
//         After NEXP digits Z = 2^F to within 2^-NEXP; the result is
//         Z * 2^I rounded to nearest even (pycore_f64_pack_round), which
//         also denormalises small results and saturates overflow to +inf.
//
// Latency: 3 (reduction) + NLOG + 4 (normalise L) + mul + 2 (align)
// + NEXP + 1 (pack) cycles; see docs/alu.md.  The result is +inf when
// the true value overflows (the FPU turns that into OverflowError) and
// +0 when it underflows.  Accuracy: better than 0.5 + 2^-11 ulp before
// the final rounding (so correctly rounded except when the exact value
// is within ~2^-64 relative of a rounding boundary).
//
// Handshake as pycore_umul_seq: level start_i, accepted when idle, one
// cycle done_o with result_o valid; withdrawing start_i aborts.
module pycore_fp_pow #(
    parameter int MUL_STEP = 14
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [63:0] op_x_i,
    input  logic [63:0] op_y_i,
    output logic [63:0] result_o,
    output logic        done_o,
    output logic        busy_o
);

    localparam int FW   = PY_POW_ROM_FW;  // fraction bits of the datapath (88)
    localparam int NLOG = 80;             // log2 digits
    localparam int NEXP = 72;             // exp2 digits
    localparam int LMW  = 75;             // bits of the normalised log2 x
    localparam int FP   = 80;             // fraction bits of y * log2 x
    localparam int WW   = FW + 2;         // residual w: sign, 1 integer, FW fraction
    localparam int AW   = FW + 3;         // accumulator: sign, 2 integer, FW fraction
    localparam int LW   = FW + 13;        // |E + log2 m'|: 13 integer bits
    localparam int QW   = 53 + LMW;       // y significand * Lm (128)
    localparam int PW   = FP + 12;        // |P| with 12 integer bits (92)

    // 4/3 * 2^52, the m' boundary (significands above it are halved).
    localparam logic [52:0] FOUR_THIRDS = 53'h15555555555555;

    typedef enum logic [3:0] {
        S_IDLE, S_RED1, S_RED2, S_LOG, S_LSUM, S_LABS, S_LCLZ, S_LNORM,
        S_MUL, S_PSH, S_PSPLIT, S_EXP, S_PACK
    } state_e;

    state_e state_r;
    logic   done_r;

    // ---- operands, unpacked in the accept cycle ----
    logic [52:0]        mx_r;             // x significand, normalised
    logic signed [12:0] ex_r;             // x = mx * 2^(ex - 52)
    logic [52:0]        my_r;
    logic signed [12:0] ey_r;             // y = my * 2^(ey - 52)
    logic               ysign_r;

    // ---- log2 ----
    logic signed [12:0] e_r;              // E of x = m' * 2^E
    logic signed [WW-1:0] r_r;            // m' - 1  (reused as w)
    logic [7:0]         j_r;              // digit index
    logic [6:0]         i_r;              // iteration count
    logic [7:0]         j0_r;
    logic signed [AW-1:0] acc_r;          // 2^j0 * log2 m'
    // ROM constants of the current digit, fetched one cycle ahead so the
    // lookup and its shifter stay off the accumulator's add path:
    //   log: CPOS[j] >> i and CNEG[j] >> i;   exp: CPOS[k] >> k
    logic [FW+1:0]      cpos_r, cneg_r;

    // ---- L = E + log2 m' ----
    logic signed [LW:0] v_r;
    logic               lsign_r;
    logic [LW-1:0]      lmag_r;
    logic [7:0]         lscale_r;
    logic [6:0]         lz_r;
    logic [LMW-1:0]     lm_r;
    logic signed [12:0] el_r;             // L = Lm * 2^eL

    // ---- P = y * L ----
    logic [QW-1:0]      q_prod;
    logic               mul_done, mul_start;
    logic [PW-1:0]      pfix_r;
    logic               huge_r;
    logic               psign_r;
    logic signed [12:0] i_int_r;          // floor(P)
    logic [FW:0]        z_r;              // 2^F, 1 integer + FW fraction bits
    logic [FW-1:0]      f_r;              // remaining F

    logic [63:0]        result_r;

    // ------------------------------------------------------------------
    // Accept-cycle unpacking
    // ------------------------------------------------------------------
    logic [52:0] x_sig, y_sig;
    logic [5:0]  x_lz, y_lz;
    logic [10:0] x_exp, y_exp;

    assign x_sig = pycore_f64_sig(op_x_i);
    assign y_sig = pycore_f64_sig(op_y_i);
    assign x_lz  = pycore_clz53(x_sig);
    assign y_lz  = pycore_clz53(y_sig);
    assign x_exp = pycore_f64_exp_eff(op_x_i);
    assign y_exp = pycore_f64_exp_eff(op_y_i);

    // ------------------------------------------------------------------
    // Reduction: r = m' - 1 as a WW-bit signed fixed-point number
    // ------------------------------------------------------------------
    logic                 halve;
    logic signed [WW-1:0] r_red;
    logic [FW-1:0]        r_mag;
    logic [7:0]           r_clz;
    logic [7:0]           j0_sel;

    logic [52:0]          r_delta;        // 2^53 - mx  (< 2^52 here)
    assign halve   = (mx_r > FOUR_THIRDS);
    assign r_delta = 53'((54'd1 << 53) - 54'(mx_r));
    // mx/2^52 - 1 = 0.mx[51:0]  (>= 0);  mx/2^53 - 1 = -(2^53 - mx)/2^53 (< 0)
    assign r_red = halve ? -$signed({{(WW-FW){1'b0}}, r_delta,    {(FW-53){1'b0}}})
                         :  $signed({{(WW-FW){1'b0}}, mx_r[51:0], {(FW-52){1'b0}}});
    assign r_mag = r_r[WW-1] ? FW'(-r_r) : r_r[FW-1:0];

    // leading zeros of |r| over its FW fraction bits (|r| < 1/2)
    always_comb begin
        r_clz = 8'(FW);
        for (int b = 0; b < FW; b++) if (r_mag[b]) r_clz = 8'(FW - 1 - b);
    end
    assign j0_sel = (r_clz < 8'd2) ? 8'd2 : r_clz;

    // ------------------------------------------------------------------
    // Shared recurrence datapath
    //   shifter A: w >>> j (log) or Z >> k (exp)
    //   shifter B: next ROM constant >> next shift (prefetch register)
    // ------------------------------------------------------------------
    logic                 in_log;
    logic [7:0]           k_idx;          // j (log) or k (exp)
    logic                 d_pos, d_neg;   // log digit
    logic signed [WW-1:0] w_sh;           // w >>> j
    logic [FW:0]          z_sh;           // Z >> k
    logic signed [WW-1:0] w_next;
    logic signed [AW-1:0] acc_next;
    logic [FW-1:0]        exp_c;          // log2(1 + 2^-k), FW fraction bits
    logic                 exp_take;

    assign in_log = (state_r == S_LOG);
    assign k_idx  = in_log ? j_r : {1'b0, i_r};
    // digit: +1 for w >= 1/2, -1 for w < -1/2, else 0
    assign d_pos  = !r_r[WW-1] && (r_r[WW-2:WW-3] != 2'b00);
    assign d_neg  =  r_r[WW-1] && (r_r[WW-2:WW-3] != 2'b11);

    // (kept as its own signed assignment: inside an unsigned context the
    // arithmetic shift would silently turn logical)
    logic signed [WW-1:0] w_sh_full;
    assign w_sh_full = r_r >>> k_idx[6:0];
    assign w_sh      = (k_idx >= 8'(WW)) ? $signed({WW{r_r[WW-1]}}) : w_sh_full;
    assign z_sh      = z_r >> k_idx[6:0];

    always_comb begin
        // w' = 2 (w - d + d (w >>> j))
        if (d_pos)      w_next = (r_r - $signed({{(WW-FW-1){1'b0}}, 1'b1, {FW{1'b0}}}) + w_sh) <<< 1;
        else if (d_neg) w_next = (r_r + $signed({{(WW-FW-1){1'b0}}, 1'b1, {FW{1'b0}}}) - w_sh) <<< 1;
        else            w_next = r_r <<< 1;
        // acc' = acc - CPOS[j] 2^-i  (d = +1)   or   acc + CNEG[j] 2^-i  (d = -1)
        if (d_pos)      acc_next = acc_r - $signed({1'b0, cpos_r});
        else if (d_neg) acc_next = acc_r + $signed({1'b0, cneg_r});
        else            acc_next = acc_r;
    end

    assign exp_c    = cpos_r[FW-1:0];     // CPOS[k] >> k  (< 1 for k >= 1)
    assign exp_take = (f_r >= exp_c);

    // Prefetch: constants for the digit handled in the next cycle.
    //   S_RED2 -> first log digit (j0, i = 0);  S_LOG -> (j + 1, i + 1)
    //   S_PSPLIT -> first exp digit (k = 1);    S_EXP -> k + 1
    logic [7:0]    pf_k;
    logic [6:0]    pf_sh;
    logic [FW+1:0] pf_pos, pf_neg;
    always_comb begin
        unique case (state_r)
            S_RED2:  begin pf_k = j0_sel;       pf_sh = 7'd0; end
            S_LOG:   begin pf_k = j_r + 8'd1;   pf_sh = i_r + 7'd1; end
            S_PSPLIT: begin pf_k = 8'd1;        pf_sh = 7'd1; end
            default: begin pf_k = {1'b0, i_r} + 8'd1; pf_sh = i_r + 7'd1; end   // S_EXP
        endcase
    end
    assign pf_pos = pycore_pow_rom(1'b0, pf_k) >> pf_sh;
    assign pf_neg = pycore_pow_rom(1'b1, pf_k) >> pf_sh;

    // ------------------------------------------------------------------
    // L = E + acc 2^-j0 : sign / magnitude, then normalise to LMW bits
    // ------------------------------------------------------------------
    logic signed [LW:0]   v_sum;          // E 2^FW + acc 2^-j0  (E != 0) or acc (E == 0)
    logic [6:0]           lmag_clz;
    logic [LW-1:0]        lmag_norm;

    always_comb begin
        if (e_r == 13'sd0) begin
            v_sum = $signed({{(LW+1-AW){acc_r[AW-1]}}, acc_r});
        end else begin
            v_sum = $signed({{(LW+1-13){e_r[12]}}, e_r}) <<< FW;
            v_sum = v_sum + ($signed({{(LW+1-AW){acc_r[AW-1]}}, acc_r}) >>> j0_r);
        end
        lmag_clz = 7'(LW);
        for (int b = 0; b < LW; b++) if (lmag_r[b]) lmag_clz = 7'(LW - 1 - b);
    end
    assign lmag_norm = lmag_r << lz_r;

    // ------------------------------------------------------------------
    // P = y * L
    // ------------------------------------------------------------------
    pycore_umul_seq #(.AW(LMW), .BW(53), .STEP(MUL_STEP)) u_mul (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .start_i(mul_start),
        .op_a_i(lm_r), .op_b_i(my_r),
        .product_o(q_prod), .done_o(mul_done), .busy_o()
    );
    assign mul_start = (state_r == S_MUL);

    // P = Q * 2^(ey - 52 + eL);  Pfix = P * 2^FP = Q >> t,  t = -(ey - 52 + eL + FP)
    logic signed [13:0] p_sh;
    logic [13:0]        t_amt;
    logic [QW-1:0]      q_shifted;
    logic               p_huge;
    logic signed [PW:0] pfix_s;

    assign p_sh      = 14'(ey_r) - 14'sd52 + 14'(el_r) + 14'(FP);
    assign t_amt     = -p_sh;
    assign q_shifted = (p_sh >= 14'sd0) ? q_prod :
                       ((t_amt >= 14'(QW)) ? '0 : (q_prod >> t_amt[7:0]));
    assign p_huge    = (p_sh >= 14'sd0) ? (q_prod != '0) : (q_shifted[QW-1:PW-1] != '0);
    assign pfix_s    = psign_r ? -$signed({1'b0, pfix_r}) : $signed({1'b0, pfix_r});

    // ------------------------------------------------------------------
    // Pack: Z * 2^I rounded to nearest even
    // ------------------------------------------------------------------
    logic [63:0] pack_res;
    assign pack_res = pycore_f64_pack_round(
        1'b0, $signed({i_int_r[12], i_int_r}) + 14'sd1023,
        z_r[FW:FW-52], z_r[FW-53], z_r[FW-54], |z_r[FW-55:0]);

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r  <= S_IDLE;
            done_r   <= 1'b0;
            mx_r <= '0; ex_r <= '0; my_r <= '0; ey_r <= '0; ysign_r <= 1'b0;
            e_r <= '0; r_r <= '0; j_r <= '0; i_r <= '0; j0_r <= '0; acc_r <= '0;
            v_r <= '0; lsign_r <= 1'b0; lmag_r <= '0; lscale_r <= '0; lz_r <= '0; lm_r <= '0; el_r <= '0;
            cpos_r <= '0; cneg_r <= '0;
            pfix_r <= '0; huge_r <= 1'b0; psign_r <= 1'b0; i_int_r <= '0;
            z_r <= '0; f_r <= '0;
            result_r <= '0;
        end else begin
            done_r <= 1'b0;
            if (state_r != S_IDLE && !start_i) begin
                state_r <= S_IDLE;                      // requester withdrew
            end else begin
                unique case (state_r)
                    S_IDLE: if (start_i && !done_r) begin
                        mx_r    <= x_sig << x_lz;
                        ex_r    <= 13'(x_exp) - 13'(x_lz) - 13'sd1023;
                        my_r    <= y_sig << y_lz;
                        ey_r    <= 13'(y_exp) - 13'(y_lz) - 13'sd1023;
                        ysign_r <= op_y_i[63];
                        state_r <= S_RED1;
                    end
                    S_RED1: begin
                        r_r     <= r_red;
                        e_r     <= halve ? ex_r + 13'sd1 : ex_r;
                        acc_r   <= '0;
                        state_r <= S_RED2;
                    end
                    S_RED2: begin
                        // w_j0 = -r * 2^j0 (exact); digits below j0 are zero
                        r_r     <= (-r_r) <<< j0_sel;
                        j0_r    <= j0_sel;
                        j_r     <= j0_sel;
                        i_r     <= '0;
                        cpos_r  <= pf_pos;
                        cneg_r  <= pf_neg;
                        state_r <= (r_mag == '0) ? S_LSUM : S_LOG;
                    end
                    S_LOG: begin
                        r_r    <= w_next;
                        acc_r  <= acc_next;
                        j_r    <= j_r + 8'd1;
                        i_r    <= i_r + 7'd1;
                        cpos_r <= pf_pos;
                        cneg_r <= pf_neg;
                        if (i_r == 7'(NLOG - 1)) state_r <= S_LSUM;
                    end
                    S_LSUM: begin
                        v_r      <= v_sum;
                        lscale_r <= (e_r == 13'sd0) ? j0_r : 8'd0;
                        state_r  <= S_LABS;
                    end
                    S_LABS: begin
                        lsign_r <= v_r[LW];
                        lmag_r  <= LW'(v_r[LW] ? -v_r : v_r);
                        state_r <= S_LCLZ;
                    end
                    S_LCLZ: begin
                        lz_r    <= lmag_clz;
                        state_r <= S_LNORM;
                    end
                    S_LNORM: begin
                        // L = Lm * 2^eL with Lm the top LMW bits of the normalised magnitude
                        lm_r    <= lmag_norm[LW-1:LW-LMW];
                        el_r    <= 13'(LW - LMW) - 13'(lz_r) - 13'(FW) - 13'(lscale_r);
                        psign_r <= ysign_r ^ lsign_r;
                        state_r <= S_MUL;
                    end
                    S_MUL: if (mul_done) begin
                        state_r <= S_PSH;
                    end
                    S_PSH: begin
                        pfix_r  <= q_shifted[PW-1:0];
                        huge_r  <= p_huge;
                        state_r <= S_PSPLIT;
                    end
                    S_PSPLIT: begin
                        // P = I + F, F in [0, 1): two's complement split
                        i_int_r <= pfix_s[PW:FP];
                        f_r     <= {pfix_s[FP-1:0], {(FW-FP){1'b0}}};
                        z_r     <= {1'b1, {FW{1'b0}}};
                        i_r     <= 7'd1;
                        cpos_r  <= pf_pos;
                        state_r <= huge_r ? S_PACK : S_EXP;
                    end
                    S_EXP: begin
                        if (exp_take) begin
                            f_r <= f_r - exp_c;
                            z_r <= z_r + z_sh;
                        end
                        i_r    <= i_r + 7'd1;
                        cpos_r <= pf_pos;
                        if (i_r == 7'(NEXP)) state_r <= S_PACK;
                    end
                    S_PACK: begin
                        if (huge_r) result_r <= psign_r ? PY_F64_PZERO : PY_F64_PINF;
                        else        result_r <= pack_res;
                        done_r  <= 1'b1;
                        state_r <= S_IDLE;
                    end
                    default: state_r <= S_IDLE;
                endcase
            end
        end
    end

    assign result_o = result_r;
    assign done_o   = done_r;
    assign busy_o   = (state_r != S_IDLE);

endmodule
