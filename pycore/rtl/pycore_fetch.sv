`include "pycore_defs.svh"

// Instruction fetch as an imem master. Each instruction is a 64-bit slot; the
// fetch unit drives a byte address (pc << 3) and consumes the registered read
// data one cycle later via the req/ack handshake. EXTENDED_ARG folding and CACHE
// skipping are preserved. There is no combinational use of imem_rdata.
module pycore_fetch #(
    parameter int ADDR_WIDTH = PYCORE_ADDR_WIDTH,
    parameter int DATA_WIDTH = PYCORE_IMEM_DATA_WIDTH
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  stall,
    input  logic                  flush,
    input  logic                  branch_taken,
    input  logic [31:0]           branch_target,
    // imem master port
    output logic                  imem_req,
    output logic                  imem_we,
    output logic [ADDR_WIDTH-1:0] imem_addr,
    output logic [DATA_WIDTH-1:0] imem_wdata,
    input  logic                  imem_ack,
    input  logic [DATA_WIDTH-1:0] imem_rdata,
    // decode-facing outputs
    output logic                  instr_valid,
    output logic [7:0]            opcode,
    output logic [31:0]           arg,
    output logic [31:0]           pc
);

    logic [31:0] pc_q;
    logic [31:0] arg_prefix_q;
    logic        have_prefix_q;
    logic        awaiting_q;   // a request is outstanding, ack expected next cycle

    function automatic logic [3:0] cache_count(input logic [7:0] op);
        begin
            unique case (op)
                default: cache_count = 4'd0;
            endcase
        end
    endfunction

    // Issue a fetch only when not stalled and not already waiting on an ack.
    assign imem_req   = !stall && !awaiting_q && rst_n;
    assign imem_we    = 1'b0;
    assign imem_wdata = '0;
    assign imem_addr  = {pc_q[ADDR_WIDTH-4:0], 3'b000};  // pc_q << 3 (8-byte slots)

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0]  fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;
        logic [3:0]  cache_slots;

        if (!rst_n) begin
            pc_q <= 32'b0;
            arg_prefix_q <= 32'b0;
            have_prefix_q <= 1'b0;
            awaiting_q <= 1'b0;
            instr_valid <= 1'b0;
            opcode <= 8'b0;
            arg <= 32'b0;
            pc <= 32'b0;
        end else if (!stall) begin
            instr_valid <= 1'b0;
            opcode <= 8'b0;
            arg <= 32'b0;
            pc <= 32'b0;

            if (flush) begin
                have_prefix_q <= 1'b0;
                arg_prefix_q <= 32'b0;
                awaiting_q <= 1'b0;
            end else if (branch_taken) begin
                pc_q <= branch_target;
                have_prefix_q <= 1'b0;
                arg_prefix_q <= 32'b0;
                awaiting_q <= 1'b0;
            end else if (!awaiting_q) begin
                // imem_req asserted combinationally this cycle; ack arrives next.
                awaiting_q <= 1'b1;
            end else if (imem_ack) begin
                awaiting_q <= 1'b0;

                fetched_opcode = imem_rdata[7:0];
                fetched_arg = imem_rdata[39:8];
                folded_arg = have_prefix_q ? ((arg_prefix_q << 8) | fetched_arg[7:0]) : fetched_arg;
                cache_slots = cache_count(fetched_opcode);

                if (fetched_opcode == PY_OP_CACHE) begin
                    pc_q <= pc_q + 1;
                end else if (fetched_opcode == PY_OP_EXTENDED_ARG) begin
                    arg_prefix_q <= folded_arg;
                    have_prefix_q <= 1'b1;
                    pc_q <= pc_q + 1;
                end else begin
                    instr_valid <= 1'b1;
                    opcode <= fetched_opcode;
                    arg <= folded_arg;
                    pc <= pc_q;
                    have_prefix_q <= 1'b0;
                    arg_prefix_q <= 32'b0;
                    pc_q <= pc_q + 1 + cache_slots;
                end
            end
        end
    end

endmodule
