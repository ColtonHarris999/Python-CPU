`include "pycore_defs.svh"

// Integer power (INT ** INT) by MSB-first square-and-multiply on the
// shared pycore_mul.  The multiplier is owned by this sequencer only while
// busy_o is high; pycore_exec muxes the bus.
//
//   exp < 0           trap in the accept cycle (the result is a float in
//                     Python; pycore_exec re-routes that case to the FPU
//                     before it reaches this unit)
//   exp == 0          1, in the accept cycle
//   otherwise         bits(exp) - 1 squarings plus one multiply per set
//                     bit below the MSB, each a full pycore_mul pass, with a
//                     trap (pycore_exec reports PY_TRAP_OVERFLOW) as soon as
//                     an intermediate product leaves the signed 64-bit range
//                     (Python would promote to a big int).  Bases 0, 1 and
//                     -1 never overflow, so any exponent is accepted for them.
//
// Handshake as in pycore_umul_seq.sv; trap_o takes the place of done_o
// when the operation ends in a trap.
module pycore_ipow (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [63:0] base_i,
    input  logic [63:0] exp_i,
    // shared multiplier
    output logic        mul_start_o,
    output logic [63:0] mul_a_o,
    output logic [63:0] mul_b_o,
    input  logic [63:0] mul_lo_i,
    input  logic [63:0] mul_hi_i,
    input  logic        mul_done_i,
    // results
    output logic [63:0] result_o,
    output logic        trap_o,
    output logic        done_o,
    output logic        stall_o,
    output logic        busy_o
);

    typedef enum logic [2:0] {
        P_IDLE, P_NORM, P_STEP, P_SQR, P_MUL, P_DONE, P_TRAP
    } state_e;

    state_e      state_r;
    logic [63:0] acc_r;
    logic [63:0] bits_r;          // exponent bits below the MSB, MSB first
    logic [6:0]  cnt_r;
    logic [63:0] result_r;

    logic        exp_neg, exp_zero;
    logic        overflow;
    logic [6:0]  lz;

    assign exp_neg  = exp_i[63];
    assign exp_zero = (exp_i == 64'd0);
    assign overflow = (mul_hi_i != {64{mul_lo_i[63]}});
    assign lz       = pycore_clz64(bits_r);

    assign mul_start_o = (state_r == P_SQR) || (state_r == P_MUL);
    assign mul_a_o     = acc_r;
    assign mul_b_o     = (state_r == P_SQR) ? acc_r : base_i;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r  <= P_IDLE;
            acc_r    <= '0;
            bits_r   <= '0;
            cnt_r    <= '0;
            result_r <= '0;
        end else if (!start_i) begin
            state_r <= P_IDLE;
        end else begin
            unique case (state_r)
                P_IDLE: begin
                    if (!exp_neg && !exp_zero) begin
                        acc_r   <= base_i;
                        bits_r  <= exp_i;
                        state_r <= P_NORM;
                    end
                end
                P_NORM: begin
                    bits_r  <= bits_r << (lz + 7'd1);
                    cnt_r   <= 7'd63 - lz;
                    state_r <= P_STEP;
                end
                P_STEP: begin
                    if (cnt_r == 7'd0) begin
                        result_r <= acc_r;
                        state_r  <= P_DONE;
                    end else begin
                        state_r <= P_SQR;
                    end
                end
                P_SQR: if (mul_done_i) begin
                    acc_r <= mul_lo_i;
                    if (overflow) begin
                        state_r <= P_TRAP;
                    end else if (bits_r[63]) begin
                        state_r <= P_MUL;
                    end else begin
                        bits_r  <= bits_r << 1;
                        cnt_r   <= cnt_r - 7'd1;
                        state_r <= P_STEP;
                    end
                end
                P_MUL: if (mul_done_i) begin
                    acc_r   <= mul_lo_i;
                    bits_r  <= bits_r << 1;
                    cnt_r   <= cnt_r - 7'd1;
                    state_r <= overflow ? P_TRAP : P_STEP;
                end
                P_DONE, P_TRAP: state_r <= P_IDLE;
                default:        state_r <= P_IDLE;
            endcase
        end
    end

    always_comb begin
        result_o = result_r;
        done_o   = 1'b0;
        trap_o   = 1'b0;
        unique case (state_r)
            P_IDLE: begin
                if (start_i) begin
                    if (exp_neg) begin
                        trap_o = 1'b1;
                    end else if (exp_zero) begin
                        done_o   = 1'b1;
                        result_o = 64'd1;
                    end
                end
            end
            P_DONE: done_o = 1'b1;
            P_TRAP: trap_o = 1'b1;
            default: ;
        endcase
    end

    assign stall_o = start_i && !done_o && !trap_o;
    assign busy_o  = (state_r != P_IDLE);

endmodule
