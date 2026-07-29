`include "pycore_defs.svh"

// Instruction fetch as an imem master. Each instruction is a 64-bit slot; the
// fetch unit drives a byte address (pc_o << 3) and consumes the registered read
// data one cycle later via the req/ack handshake.
//
// EXTENDED_ARG folding and CACHE skipping are preserved. CACHE slots are
// skipped by opcode value 0 in the slot stream (independent of any cache-count
// map) so 1:1-transcoded CPython streams with real CACHE units work correctly.
//
// LOAD_CONST is a normal 1-slot instruction: arg selects co_consts[N]; the
// constant value is read from dmem by CONT_LOAD_CONST (no inline encoding).
module pycore_fetch #(
    parameter int ADDR_WIDTH = PYCORE_ADDR_WIDTH,
    parameter int DATA_WIDTH = PYCORE_IMEM_DATA_WIDTH
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,
    input  logic                  stall_i,
    input  logic                  flush_i,
    input  logic                  branch_taken_i,
    input  logic [31:0]           branch_target_i,
    // imem master port
    output logic                  imem_req_o,
    output logic                  imem_we_o,
    output logic [ADDR_WIDTH-1:0] imem_addr_o,
    output logic [DATA_WIDTH-1:0] imem_wdata_o,
    input  logic                  imem_ack_i,
    input  logic [DATA_WIDTH-1:0] imem_rdata_i,
    // decode-facing outputs
    output logic                  instr_valid_o,
    output logic [7:0]            opcode_o,
    output logic [31:0]           arg_o,
    output logic [31:0]           pc_o
);

    logic [31:0] pc_r;
    logic [31:0] arg_prefix_r;
    logic        have_prefix_r;
    logic        awaiting_r;    // a request is outstanding, ack expected next cycle

    // Issue a fetch only when not stalled and not already waiting on an ack.
    assign imem_req_o   = !stall_i && !awaiting_r && rst_n_i;
    assign imem_we_o    = 1'b0;
    assign imem_wdata_o = '0;
    assign imem_addr_o  = {pc_r[ADDR_WIDTH-4:0], 3'b000};  // pc_r << 3 (8-byte slots)

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [7:0]  fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;

        if (!rst_n_i) begin
            pc_r            <= 32'b0;
            arg_prefix_r    <= 32'b0;
            have_prefix_r   <= 1'b0;
            awaiting_r      <= 1'b0;
            instr_valid_o   <= 1'b0;
            opcode_o        <= 8'b0;
            arg_o           <= 32'b0;
            pc_o            <= 32'b0;
        end else begin
            if (!stall_i) begin
                instr_valid_o <= 1'b0;
                opcode_o      <= 8'b0;
                arg_o         <= 32'b0;
                pc_o          <= 32'b0;

                if (flush_i) begin
                    have_prefix_r <= 1'b0;
                    arg_prefix_r  <= 32'b0;
                    awaiting_r    <= 1'b0;
                end else if (branch_taken_i) begin
                    pc_r          <= branch_target_i;
                    have_prefix_r <= 1'b0;
                    arg_prefix_r  <= 32'b0;
                    awaiting_r    <= 1'b0;
                end else if (!awaiting_r) begin
                    // imem_req_o asserted combinationally this cycle; ack arrives next.
                    awaiting_r <= 1'b1;
                end else if (imem_ack_i) begin
                    awaiting_r <= 1'b0;

                    fetched_opcode = imem_rdata_i[7:0];
                    fetched_arg    = imem_rdata_i[39:8];
                    folded_arg     = have_prefix_r ?
                                     ((arg_prefix_r << 8) | fetched_arg[7:0])
                                     : fetched_arg;

                    if (fetched_opcode == PY_OP_CACHE) begin
                        // Skip CACHE by opcode value 0 — works for transcoded
                        // streams that contain real CPython CACHE units.
                        pc_r <= pc_r + 1;

                    end else if (fetched_opcode == PY_OP_EXTENDED_ARG) begin
                        arg_prefix_r  <= folded_arg;
                        have_prefix_r <= 1'b1;
                        pc_r          <= pc_r + 1;

                    end else begin
                        instr_valid_o <= 1'b1;
                        opcode_o      <= fetched_opcode;
                        arg_o         <= folded_arg;
                        pc_o          <= pc_r;
                        have_prefix_r <= 1'b0;
                        arg_prefix_r  <= 32'b0;
                        pc_r          <= pc_r + 1;
                    end
                end
            end
        end
    end

endmodule
