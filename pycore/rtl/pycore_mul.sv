`include "pycore_defs.svh"

// Signed 64 x 64 -> 128 integer multiplier, STEP multiplier bits per clock
// (64/STEP + 1 cycles from accept to done_o; 5 cycles at the default
// STEP = 16).  Each cycle multiplies the full 64-bit multiplicand by one
// STEP-bit chunk of the multiplier and folds it into a shift-right
// accumulator, so the per-cycle datapath is one 65 x (STEP+1) signed
// multiply-accumulate.  The multiplier is treated as unsigned chunks with
// the top chunk signed, which makes the running sum the exact signed
// product without a final correction step.
//
// Handshake: see pycore_umul_seq.sv (level start_i, one-cycle done_o,
// withdrawing start_i aborts).  stall_o is start_i && !done_o, so the
// requester can tie it straight into its hold condition.
module pycore_mul #(
    parameter int STEP = 16
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,      // product[63:0]  (Python int wraps)
    output logic [63:0] result_hi_o,   // product[127:64]
    output logic        done_o,
    output logic        stall_o,
    output logic        busy_o
);

    localparam int NSTEP = 64 / STEP;
    localparam int ACC_W = 64 + STEP + 2;
    localparam int CNT_W = (NSTEP > 1) ? $clog2(NSTEP) : 1;

    initial begin
        if ((64 % STEP) != 0) $fatal(1, "pycore_mul: STEP must divide 64");
    end

    logic                    busy_r;
    logic                    done_r;
    logic [CNT_W-1:0]        cnt_r;
    logic [63:0]             a_r;
    logic [63:0]             b_r;
    logic signed [ACC_W-1:0] acc_r;
    logic [63:0]             lo_r;
    logic [63:0]             lo_result_r;
    logic [63:0]             hi_result_r;

    logic [63:0]             a_cur;
    logic [63:0]             b_cur;
    logic signed [ACC_W-1:0] acc_cur;
    logic                    last_step;
    logic signed [STEP:0]    chunk_s;        // unsigned chunk, signed on top
    logic signed [64:0]      a_s;
    logic signed [64+STEP+1:0] pp;
    logic signed [ACC_W-1:0] sum;
    logic [63:0]             lo_next;
    logic                    accept;

    // No re-accept in the done cycle: the requester still holds start_i
    // while it consumes the result.
    assign accept    = start_i && !busy_r && !done_r;
    assign a_cur     = busy_r ? a_r : op_a_i;
    assign b_cur     = busy_r ? b_r : op_b_i;
    assign acc_cur   = busy_r ? acc_r : '0;
    assign last_step = busy_r ? (cnt_r == CNT_W'(NSTEP - 1)) : (NSTEP == 1);
    assign chunk_s   = {last_step ? b_cur[STEP-1] : 1'b0, b_cur[STEP-1:0]};
    assign a_s       = {a_cur[63], a_cur};
    assign pp        = a_s * chunk_s;
    assign sum       = (acc_cur >>> STEP) + ACC_W'(pp);
    assign lo_next   = 64'(lo_r >> STEP) | 64'(64'(sum[STEP-1:0]) << (64 - STEP));

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            busy_r      <= 1'b0;
            done_r      <= 1'b0;
            cnt_r       <= '0;
            a_r         <= '0;
            b_r         <= '0;
            acc_r       <= '0;
            lo_r        <= '0;
            lo_result_r <= '0;
            hi_result_r <= '0;
        end else begin
            done_r <= 1'b0;
            if (accept || busy_r) begin
                if (busy_r && !start_i) begin
                    busy_r <= 1'b0;
                end else begin
                    a_r   <= a_cur;
                    b_r   <= b_cur >> STEP;
                    acc_r <= sum;
                    lo_r  <= lo_next;
                    if (last_step) begin
                        busy_r      <= 1'b0;
                        done_r      <= 1'b1;
                        cnt_r       <= '0;
                        lo_result_r <= lo_next;
                        hi_result_r <= 64'(sum >>> STEP);
                    end else begin
                        busy_r <= 1'b1;
                        cnt_r  <= busy_r ? cnt_r + 1'b1 : CNT_W'(1);
                    end
                end
            end
        end
    end

    assign result_o    = lo_result_r;
    assign result_hi_o = hi_result_r;
    assign done_o      = done_r;
    assign stall_o     = start_i && !done_r;
    assign busy_o      = busy_r;

endmodule
