`include "pycore_defs.svh"

// Unsigned iterative multiplier: AW x BW -> AW+BW product, STEP multiplier
// bits per clock.  Each cycle forms one AW x STEP partial product and folds
// it into a shift-right accumulator, so the per-cycle datapath is a single
// AW x STEP multiply-accumulate (one carry-propagate add at the end of the
// partial-product tree).  Latency is ceil(BW/STEP) + 1 cycles from the
// accept cycle to done_o; the result is registered.
//
// Handshake (shared by every multi-cycle unit in pycore_exec):
//   * start_i is a level.  The unit accepts in the first cycle it sees
//     start_i while idle, iterates, then pulses done_o for one cycle with
//     product_o valid.  The requester holds start_i until done_o.
//   * Dropping start_i while busy aborts the operation.
//   * busy_o is high from the accept cycle until the cycle before done_o.
module pycore_umul_seq #(
    parameter int AW   = 53,
    parameter int BW   = 53,
    parameter int STEP = 14
) (
    input  logic            clk_i,
    input  logic            rst_n_i,
    input  logic            start_i,
    input  logic [AW-1:0]   op_a_i,
    input  logic [BW-1:0]   op_b_i,
    output logic [AW+BW-1:0] product_o,
    output logic            done_o,
    output logic            busy_o
);

    localparam int NSTEP  = (BW + STEP - 1) / STEP;
    localparam int BWP    = NSTEP * STEP;           // b padded to whole steps
    localparam int ACC_W  = AW + STEP + 1;          // running high part
    localparam int CNT_W  = (NSTEP > 1) ? $clog2(NSTEP) : 1;

    logic             busy_r;
    logic             done_r;
    logic [CNT_W-1:0] cnt_r;
    logic [AW-1:0]    a_r;
    logic [BWP-1:0]   b_r;                          // shifts right STEP/step
    logic [ACC_W-1:0] acc_r;
    logic [BWP-1:0]   lo_r;                         // finished low chunks
    logic [AW+BW-1:0] product_r;

    // Operands for the current step: straight from the inputs on the accept
    // cycle (so that cycle already performs step 0), registers afterwards.
    logic [AW-1:0]    a_cur;
    logic [BWP-1:0]   b_cur;
    logic [ACC_W-1:0] acc_cur;
    logic [STEP-1:0]  chunk;
    logic [AW+STEP-1:0] pp;
    logic [ACC_W-1:0] sum;
    logic [BWP-1:0]   lo_next;
    logic             accept;
    logic             last_step;

    assign accept    = start_i && !busy_r && !done_r;
    assign a_cur     = busy_r ? a_r : op_a_i;
    assign b_cur     = busy_r ? b_r : BWP'(op_b_i);
    assign acc_cur   = busy_r ? acc_r : '0;
    assign chunk     = b_cur[STEP-1:0];
    assign pp        = a_cur * chunk;
    assign sum       = (acc_cur >> STEP) + ACC_W'(pp);
    // The low STEP bits of every step's sum are final product bits; shift
    // them in from the top so the chunks land in order (written as shifts
    // so NSTEP == 1, where BWP == STEP, is still legal).
    assign lo_next   = BWP'(lo_r >> STEP) | BWP'(BWP'(sum[STEP-1:0]) << (BWP - STEP));
    assign last_step = busy_r ? (cnt_r == CNT_W'(NSTEP - 1)) : (NSTEP == 1);

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            busy_r    <= 1'b0;
            done_r    <= 1'b0;
            cnt_r     <= '0;
            a_r       <= '0;
            b_r       <= '0;
            acc_r     <= '0;
            lo_r      <= '0;
            product_r <= '0;
        end else begin
            done_r <= 1'b0;
            if (accept || busy_r) begin
                if (busy_r && !start_i) begin
                    busy_r <= 1'b0;                 // requester withdrew
                end else begin
                    a_r   <= a_cur;
                    b_r   <= b_cur >> STEP;
                    acc_r <= sum;
                    lo_r  <= lo_next;
                    if (last_step) begin
                        busy_r <= 1'b0;
                        done_r <= 1'b1;
                        cnt_r  <= '0;
                        // {high part, low chunks}; b was zero-padded to
                        // BWP bits so the true product is the low AW+BW bits.
                        product_r <= (AW+BW)'({sum[ACC_W-1:STEP], lo_next});
                    end else begin
                        busy_r <= 1'b1;
                        cnt_r  <= busy_r ? cnt_r + 1'b1 : CNT_W'(1);
                    end
                end
            end
        end
    end

    assign product_o = product_r;
    assign done_o    = done_r;
    assign busy_o    = busy_r;

endmodule
