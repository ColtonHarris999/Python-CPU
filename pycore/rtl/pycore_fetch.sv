`include "pycore_defs.svh"

// Instruction fetch as an imem master. Each instruction is a 64-bit slot; the
// fetch unit drives a byte address (pc_o << 3) and consumes the registered read
// data via the req/ack handshake (ack may arrive any number of cycles later).
//
// EXTENDED_ARG folding and CACHE skipping are preserved. CACHE slots are
// skipped by opcode value 0 in the slot stream (independent of any cache-count
// map) so 1:1-transcoded CPython streams with real CACHE units work correctly.
//
// LOAD_CONST is a normal 1-slot instruction: arg selects co_consts[N]; the
// constant value is read from dmem by CONT_LOAD_CONST (no inline encoding).
//
// P4b: a 64 B line register (8 slots + tag + valid). When `imem_line_valid_i`
// accompanies ack, the whole L1I line is captured. Subsequent slots in that
// line — including CACHE skip and EXTENDED_ARG fold — are delivered from the
// register with no memory request. The architectural PC stays in wordcode
// units (PC↔slot invariant); compaction is only inside the buffer.
module pycore_fetch #(
    parameter int ADDR_WIDTH = PYCORE_ADDR_WIDTH,
    parameter int DATA_WIDTH = PYCORE_IMEM_DATA_WIDTH,
    parameter int LINE_BYTES = PYCORE_LINE_BYTES
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
    input  logic [LINE_BYTES*8-1:0] imem_line_i,
    input  logic                  imem_line_valid_i,
    // decode-facing outputs
    output logic                  instr_valid_o,
    output logic [7:0]            opcode_o,
    output logic [31:0]           arg_o,
    output logic [31:0]           pc_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] mem_req_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] buf_hit_count_o
);

    localparam int SLOTS_PER_LINE = LINE_BYTES / (DATA_WIDTH / 8);
    localparam int SLOT_W         = $clog2(SLOTS_PER_LINE);
    localparam int LINE_W         = LINE_BYTES * 8;

    logic [31:0] pc_r;
    logic [31:0] arg_prefix_r;
    logic        have_prefix_r;
    logic        awaiting_r;
    logic        line_valid_r;
    logic [31-SLOT_W:0] line_tag_r;
    logic [LINE_W-1:0]  line_data_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] mem_req_count_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] buf_hit_count_r;

    wire line_hit = line_valid_r && (line_tag_r == pc_r[31:SLOT_W]);

    // Hold req until ack so a busy xbar cannot drop a one-cycle pulse.
    // Gate on redirect/flush: pc_r (and therefore imem_addr_o) updates NBA
    // on that cycle, so a combo request would fetch the *old* PC. With
    // ack latency > 1 that stale reply is still in flight when awaiting
    // is cleared, and is then retired as the first instruction of the
    // branch/CALL target (wrong opcode, CALL_FILTER / TYPE on image tests).
    // A line-buffer hit issues no request at all.
    assign imem_req_o   = rst_n_i && !stall_i && !flush_i && !branch_taken_i &&
                          !line_hit && (!awaiting_r || !imem_ack_i);
    assign imem_we_o    = 1'b0;
    assign imem_wdata_o = '0;
    assign imem_addr_o  = {pc_r[ADDR_WIDTH-4:0], 3'b000};  // pc_r << 3 (8-byte slots)
    assign mem_req_count_o = mem_req_count_r;
    assign buf_hit_count_o = buf_hit_count_r;

    function automatic logic [DATA_WIDTH-1:0] line_slot(
        input logic [LINE_W-1:0] line,
        input logic [SLOT_W-1:0] idx
    );
        line_slot = line[idx*DATA_WIDTH +: DATA_WIDTH];
    endfunction

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [7:0]  fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;
        logic        found;
        logic [31:0] prefix;
        logic        have;
        logic [31:0] next_pc;
        logic [DATA_WIDTH-1:0] slot;
        logic [7:0]  op;
        logic [31:0] arg;

        if (!rst_n_i) begin
            pc_r            <= 32'b0;
            arg_prefix_r    <= 32'b0;
            have_prefix_r   <= 1'b0;
            awaiting_r      <= 1'b0;
            line_valid_r    <= 1'b0;
            line_tag_r      <= '0;
            line_data_r     <= '0;
            mem_req_count_r <= '0;
            buf_hit_count_r <= '0;
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
                end else if (line_hit) begin
                    // Walk the rest of the captured line. CACHE / EXTENDED_ARG
                    // fold here; the emitted PC is still the real slot index.
                    found   = 1'b0;
                    prefix  = arg_prefix_r;
                    have    = have_prefix_r;
                    next_pc = pc_r;
                    buf_hit_count_r <= buf_hit_count_r + 1'b1;
                    for (int s = 0; s < SLOTS_PER_LINE; s++) begin
                        if (!found && (s >= int'(pc_r[SLOT_W-1:0]))) begin
                            slot = line_slot(line_data_r, s[SLOT_W-1:0]);
                            op   = slot[7:0];
                            arg  = slot[39:8];
                            folded_arg = have ? ((prefix << 8) | arg[7:0]) : arg;
                            if (op == PY_OP_CACHE) begin
                                next_pc = next_pc + 32'd1;
                            end else if (op == PY_OP_EXTENDED_ARG) begin
                                prefix  = folded_arg;
                                have    = 1'b1;
                                next_pc = next_pc + 32'd1;
                            end else begin
                                instr_valid_o <= 1'b1;
                                opcode_o      <= op;
                                arg_o         <= folded_arg;
                                pc_o          <= next_pc;
                                have          = 1'b0;
                                prefix        = 32'b0;
                                next_pc       = next_pc + 32'd1;
                                found         = 1'b1;
                            end
                        end
                    end
                    pc_r          <= next_pc;
                    have_prefix_r <= have;
                    arg_prefix_r  <= prefix;
                end else if (!awaiting_r) begin
                    awaiting_r      <= 1'b1;
                    mem_req_count_r <= mem_req_count_r + 1'b1;
                end else if (imem_ack_i) begin
                    awaiting_r <= 1'b0;
                    if (imem_line_valid_i) begin
                        line_valid_r <= 1'b1;
                        line_data_r  <= imem_line_i;
                        line_tag_r   <= pc_r[31:SLOT_W];
                    end

                    fetched_opcode = imem_rdata_i[7:0];
                    fetched_arg    = imem_rdata_i[39:8];
                    folded_arg     = have_prefix_r ?
                                     ((arg_prefix_r << 8) | fetched_arg[7:0])
                                     : fetched_arg;

                    if (fetched_opcode == PY_OP_CACHE) begin
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
