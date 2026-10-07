`include "pycore_defs.svh"

// Signed 64-bit floor division and modulo (Python // and %) on a
// radix-2**RL restoring divider (pycore_udiv_seq) with leading-zero skip:
// only bits(|a|) - bits(|b|) + 1 quotient bits are actually iterated, so
// small operands finish early.
//
//   C0            accept: sign-magnitude of both operands
//   C1            leading-zero counts, step count, align the dividend,
//                 load the divider core
//   C2 .. C(S+1)  S = ceil(n / RL) restoring steps, n = quotient bits
//   C(S+2)        core registers quotient / remainder
//   C(S+3)        Python floor fix-up, result registered
//   C(S+4)        done_o
//
// So a division takes 5 + ceil(n/2) cycles at RL = 2: 5 cycles when
// |a| < |b|, 37 for a full 64-bit quotient.  Division by zero is reported
// combinationally in the accept cycle (div_zero_o) and does not start the
// unit.  Both quotient and remainder are always produced.
//
// Handshake as in pycore_umul_seq.sv.
module pycore_div #(
    parameter int RL = 2
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] quot_o,
    output logic [63:0] rem_o,
    output logic        div_zero_o,
    output logic        done_o,
    output logic        stall_o,
    output logic        busy_o
);

    typedef enum logic [1:0] { D_IDLE, D_PREP, D_RUN, D_DONE } state_e;

    state_e      state_r;
    logic        sa_r, sb_r;
    logic [63:0] a_mag_r, b_mag_r;
    logic [63:0] quot_r, rem_r;

    // ---- C0: magnitudes ----
    logic [63:0] a_mag, b_mag;
    assign a_mag = op_a_i[63] ? (~op_a_i + 64'd1) : op_a_i;
    assign b_mag = op_b_i[63] ? (~op_b_i + 64'd1) : op_b_i;
    assign div_zero_o = start_i && (op_b_i == 64'd0);

    // ---- C1: step count and alignment ----
    logic [6:0]  lz_a, lz_b;
    logic [7:0]  bits_a, bits_b;          // 64 - clz
    logic signed [8:0] n_q;               // quotient bits needed
    logic [7:0]  n_pad;                   // rounded up to a multiple of RL
    logic [63:0] rem_init;
    logic [63:0] bits;
    logic [15:0] nsteps;

    assign lz_a   = pycore_clz64(a_mag_r);
    assign lz_b   = pycore_clz64(b_mag_r);
    assign bits_a = 8'd64 - 8'(lz_a);
    assign bits_b = 8'd64 - 8'(lz_b);
    assign n_q    = $signed(9'(bits_a)) - $signed(9'(bits_b)) + 9'sd1;

    always_comb begin
        if (n_q <= 9'sd0) begin
            n_pad = 8'd0;
        end else if (RL == 2) begin
            n_pad = (n_q[7:0] + 8'd1) & 8'hFE;
        end else begin
            n_pad = n_q[7:0];
        end
        // |a| >> n_pad is below |b| by construction; the n_pad low bits are
        // brought down one radix digit at a time.
        rem_init = a_mag_r >> n_pad;
        bits     = a_mag_r << (8'd64 - n_pad);
        nsteps   = (RL == 2) ? 16'(n_pad >> 1) : 16'(n_pad);
    end

    logic        core_start;
    logic        core_done;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        core_busy;               // implied by state_r == D_RUN
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0] q_mag, r_mag;

    assign core_start = start_i && ((state_r == D_PREP) || (state_r == D_RUN));

    pycore_udiv_seq #(.DW(64), .VW(64), .RL(RL)) u_core (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),
        .start_i    (core_start),
        .sqrt_i     (1'b0),
        .rem_init_i (rem_init),
        .bits_i     (bits),
        .divisor_i  (b_mag_r),
        .nsteps_i   (nsteps),
        .quotient_o (q_mag),
        .remainder_o(r_mag),
        .done_o     (core_done),
        .busy_o     (core_busy)
    );

    // ---- fix-up: truncated -> floor (CPython semantics) ----
    //   q_t = sign-adjusted |a| / |b|, r_t has a's sign;
    //   if r_t != 0 and signs differ: q = q_t - 1, r = r_t + b.
    // Written so that every case is one carry chain followed by a mux
    // (no chained adders):  -(|q|) - 1 == ~|q|,  and  r_t + b is
    // +-(|r| - |b|) when the signs differ.
    logic        signs_differ, fix;
    logic [63:0] q_neg, r_neg, r_minus_b, b_minus_r;
    logic [63:0] q_floor, r_floor;

    assign signs_differ = sa_r ^ sb_r;
    assign fix          = (r_mag != 64'd0) && signs_differ;
    assign q_neg        = ~q_mag + 64'd1;
    assign r_neg        = ~r_mag + 64'd1;
    assign r_minus_b    = r_mag - b_mag_r;
    assign b_minus_r    = b_mag_r - r_mag;
    always_comb begin
        if (fix) begin
            q_floor = ~q_mag;                          // -(|q|) - 1
            r_floor = sa_r ? b_minus_r : r_minus_b;    // (-|r|) + |b|  /  |r| - |b|
        end else begin
            q_floor = signs_differ ? q_neg : q_mag;
            r_floor = sa_r ? r_neg : r_mag;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r <= D_IDLE;
            sa_r <= 1'b0; sb_r <= 1'b0;
            a_mag_r <= '0; b_mag_r <= '0;
            quot_r <= '0; rem_r <= '0;
        end else if (!start_i) begin
            state_r <= D_IDLE;
        end else begin
            unique case (state_r)
                D_IDLE: begin
                    if (!div_zero_o) begin
                        sa_r    <= op_a_i[63];
                        sb_r    <= op_b_i[63];
                        a_mag_r <= a_mag;
                        b_mag_r <= b_mag;
                        state_r <= D_PREP;
                    end
                end
                D_PREP: state_r <= D_RUN;
                D_RUN: begin
                    if (core_done) begin
                        quot_r  <= q_floor;
                        rem_r   <= r_floor;
                        state_r <= D_DONE;
                    end
                end
                D_DONE:  state_r <= D_IDLE;
                default: state_r <= D_IDLE;
            endcase
        end
    end

    assign quot_o  = quot_r;
    assign rem_o   = rem_r;
    assign done_o  = (state_r == D_DONE);
    assign stall_o = start_i && !done_o && !div_zero_o;
    assign busy_o  = (state_r != D_IDLE);

endmodule
