`include "pycore_defs.svh"

// Unsigned restoring divider core, 2**RL quotient bits per clock.
//
// The caller prepares the long division (pycore_div.sv for integers,
// pycore_fp_divrem.sv for binary64 significands and fmod):
//   rem_init_i  partial remainder before the first step (must be < divisor)
//   bits_i      dividend bits still to be brought down, MSB first; zeros are
//               shifted in once they run out (that is how fmod extends the
//               dividend by the exponent difference without storing it)
//   nsteps_i    number of radix-2**RL steps to run (0 is legal)
// Every step brings down RL bits and subtracts the largest multiple of the
// divisor that fits, so the per-cycle datapath is 2**RL - 1 parallel
// (VW+RL)-bit subtractions and a priority select.  Latency is nsteps + 2
// cycles from accept to done_o (one cycle to load, one to register the
// result).  Quotient bits beyond DW are dropped.
//
// Handshake: level start_i, one-cycle done_o with registered outputs,
// withdrawing start_i while busy aborts (see pycore_umul_seq.sv).
module pycore_udiv_seq #(
    parameter int DW = 64,      // quotient / bit-stream width
    parameter int VW = 64,      // divisor / remainder width
    parameter int RL = 2        // log2(radix): 1 or 2
) (
    input  logic          clk_i,
    input  logic          rst_n_i,
    input  logic          start_i,
    input  logic [VW-1:0] rem_init_i,
    input  logic [DW-1:0] bits_i,
    input  logic [VW-1:0] divisor_i,
    input  logic [15:0]   nsteps_i,
    output logic [DW-1:0] quotient_o,
    output logic [VW-1:0] remainder_o,
    output logic          done_o,
    output logic          busy_o
);

    localparam int TW = VW + RL;          // trial remainder width

    initial begin
        if (RL != 1 && RL != 2) $fatal(1, "pycore_udiv_seq: RL must be 1 or 2");
    end

    logic          busy_r;
    logic          done_r;
    logic [15:0]   steps_r;
    logic [VW-1:0] rem_r;
    logic [DW-1:0] bits_r;
    logic [TW-1:0] d1_r;                  // divisor multiples (1x, 2x, 3x)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [TW-1:0] d2_r;                  // radix-4 only
    logic [TW-1:0] d3_r;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [DW-1:0] q_r;
    logic [DW-1:0] q_result_r;
    logic [VW-1:0] rem_result_r;

    logic [TW-1:0] trial;
    logic [TW:0]   s1;                    // trial - k*d, bit TW is borrow
    logic [RL-1:0] qbits;
    logic [VW-1:0] rem_next;

    assign trial = {rem_r, bits_r[DW-1 -: RL]};
    assign s1 = {1'b0, trial} - {1'b0, d1_r};

    generate
        if (RL == 2) begin : gen_radix4
            logic [TW:0] s2, s3;
            assign s2 = {1'b0, trial} - {1'b0, d2_r};
            assign s3 = {1'b0, trial} - {1'b0, d3_r};
            always_comb begin
                if (!s3[TW]) begin
                    qbits    = 2'd3;
                    rem_next = s3[VW-1:0];
                end else if (!s2[TW]) begin
                    qbits    = 2'd2;
                    rem_next = s2[VW-1:0];
                end else if (!s1[TW]) begin
                    qbits    = 2'd1;
                    rem_next = s1[VW-1:0];
                end else begin
                    qbits    = 2'd0;
                    rem_next = trial[VW-1:0];
                end
            end
        end else begin : gen_radix2
            always_comb begin
                if (!s1[TW]) begin
                    qbits    = 1'b1;
                    rem_next = s1[VW-1:0];
                end else begin
                    qbits    = 1'b0;
                    rem_next = trial[VW-1:0];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            busy_r       <= 1'b0;
            done_r       <= 1'b0;
            steps_r      <= '0;
            rem_r        <= '0;
            bits_r       <= '0;
            d1_r         <= '0;
            d2_r         <= '0;
            d3_r         <= '0;
            q_r          <= '0;
            q_result_r   <= '0;
            rem_result_r <= '0;
        end else begin
            done_r <= 1'b0;
            if (start_i && !busy_r && !done_r) begin
                busy_r  <= 1'b1;
                steps_r <= nsteps_i;
                rem_r   <= rem_init_i;
                bits_r  <= bits_i;
                d1_r    <= TW'(divisor_i);
                d2_r    <= TW'(divisor_i) << 1;
                d3_r    <= TW'(divisor_i) + (TW'(divisor_i) << 1);
                q_r     <= '0;
            end else if (busy_r) begin
                if (!start_i) begin
                    busy_r <= 1'b0;
                end else if (steps_r == 16'd0) begin
                    busy_r       <= 1'b0;
                    done_r       <= 1'b1;
                    q_result_r   <= q_r;
                    rem_result_r <= rem_r;
                end else begin
                    steps_r <= steps_r - 16'd1;
                    rem_r   <= rem_next;
                    bits_r  <= bits_r << RL;
                    q_r     <= (q_r << RL) | DW'(qbits);
                end
            end
        end
    end

    assign quotient_o  = q_result_r;
    assign remainder_o = rem_result_r;
    assign done_o      = done_r;
    assign busy_o      = busy_r;

endmodule
