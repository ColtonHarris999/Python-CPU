`include "pycore_defs.svh"

// Instruction fetch as an imem master. Each instruction is a 64-bit slot; the
// fetch unit drives a byte address (pc << 3) and consumes the registered read
// data one cycle later via the req/ack handshake. EXTENDED_ARG folding and CACHE
// skipping are preserved. There is no combinational use of imem_rdata.
//
// LOAD_CONST is a variable-length instruction that spans 3 consecutive imem
// slots. The first slot carries the opcode and the 3-bit tag in bits [63:61];
// the second and third slots carry value[127:64] and value[63:0] respectively.
// The fetch unit transparently assembles all three reads before asserting
// instr_valid, so the rest of the pipeline sees a single-cycle LOAD_CONST
// completion carrying the full 131-bit tagged constant in inline_const.
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
    output logic [31:0]           pc,
    // Inline constant assembled from the three LOAD_CONST imem slots.
    // Valid only when instr_valid is high and opcode == PY_OP_LOAD_CONST.
    output logic [PYCORE_ENTRY_WIDTH-1:0] inline_const
);

    // Sub-states for the three-slot LOAD_CONST fetch sequence.
    localparam logic [1:0] FS_NORMAL   = 2'd0;  // standard single-slot fetch
    localparam logic [1:0] FS_CONST_W1 = 2'd1;  // reading value[127:64]
    localparam logic [1:0] FS_CONST_W2 = 2'd2;  // reading value[63:0]

    logic [31:0] pc_q;
    logic [31:0] arg_prefix_q;
    logic        have_prefix_q;
    logic        awaiting_q;   // a request is outstanding, ack expected next cycle
    logic [1:0]  fsub_q;       // LOAD_CONST multi-word sub-state
    logic [2:0]  lc_tag_q;     // tag[2:0] captured from LOAD_CONST slot 0 bits[63:61]
    logic [63:0] lc_hi_q;      // value[127:64] captured from LOAD_CONST slot 1

    // Issue a fetch only when not stalled and not already waiting on an ack.
    assign imem_req   = !stall && !awaiting_q && rst_n;
    assign imem_we    = 1'b0;
    assign imem_wdata = '0;
    assign imem_addr  = {pc_q[ADDR_WIDTH-4:0], 3'b000};  // pc_q << 3 (8-byte slots)

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0]  fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;

        if (!rst_n) begin
            pc_q          <= 32'b0;
            arg_prefix_q  <= 32'b0;
            have_prefix_q <= 1'b0;
            awaiting_q    <= 1'b0;
            fsub_q        <= FS_NORMAL;
            lc_tag_q      <= 3'b0;
            lc_hi_q       <= 64'b0;
            instr_valid   <= 1'b0;
            opcode        <= 8'b0;
            arg           <= 32'b0;
            pc            <= 32'b0;
            inline_const  <= '0;
        end else if (!stall) begin
            instr_valid <= 1'b0;
            opcode      <= 8'b0;
            arg         <= 32'b0;
            pc          <= 32'b0;

            if (flush) begin
                have_prefix_q <= 1'b0;
                arg_prefix_q  <= 32'b0;
                awaiting_q    <= 1'b0;
                fsub_q        <= FS_NORMAL;
            end else if (branch_taken) begin
                pc_q          <= branch_target;
                have_prefix_q <= 1'b0;
                arg_prefix_q  <= 32'b0;
                awaiting_q    <= 1'b0;
                fsub_q        <= FS_NORMAL;
            end else if (!awaiting_q) begin
                // imem_req asserted combinationally this cycle; ack arrives next.
                awaiting_q <= 1'b1;
            end else if (imem_ack) begin
                awaiting_q <= 1'b0;

                unique case (fsub_q)

                    // ----------------------------------------------------------
                    // FS_NORMAL: read a standard 1-slot instruction (or the first
                    // slot of a LOAD_CONST 3-slot sequence).
                    // ----------------------------------------------------------
                    FS_NORMAL: begin
                        fetched_opcode = imem_rdata[7:0];
                        fetched_arg    = imem_rdata[39:8];
                        folded_arg     = have_prefix_q ?
                                         ((arg_prefix_q << 8) | fetched_arg[7:0])
                                         : fetched_arg;

                        if (fetched_opcode == PY_OP_CACHE) begin
                            pc_q <= pc_q + 1;

                        end else if (fetched_opcode == PY_OP_EXTENDED_ARG) begin
                            arg_prefix_q  <= folded_arg;
                            have_prefix_q <= 1'b1;
                            pc_q          <= pc_q + 1;

                        end else if (fetched_opcode == PY_OP_LOAD_CONST) begin
                            // LOAD_CONST slot 0: tag lives in bits [63:61].
                            // Transition to FS_CONST_W1 to read value[127:64].
                            lc_tag_q      <= imem_rdata[63:61];
                            have_prefix_q <= 1'b0;
                            arg_prefix_q  <= 32'b0;
                            fsub_q        <= FS_CONST_W1;
                            pc_q          <= pc_q + 1;

                        end else begin
                            instr_valid   <= 1'b1;
                            opcode        <= fetched_opcode;
                            arg           <= folded_arg;
                            pc            <= pc_q;
                            have_prefix_q <= 1'b0;
                            arg_prefix_q  <= 32'b0;
                            pc_q          <= pc_q + 1;
                        end
                    end

                    // ----------------------------------------------------------
                    // FS_CONST_W1: second slot of LOAD_CONST holds value[127:64].
                    // ----------------------------------------------------------
                    FS_CONST_W1: begin
                        lc_hi_q <= imem_rdata[63:0];
                        fsub_q  <= FS_CONST_W2;
                        pc_q    <= pc_q + 1;
                    end

                    // ----------------------------------------------------------
                    // FS_CONST_W2: third slot holds value[63:0]. Assemble the
                    // complete 131-bit tagged entry and present the instruction.
                    // The reported PC is the slot address of the first word (word 0),
                    // which is two slots behind the current pc_q.
                    // ----------------------------------------------------------
                    FS_CONST_W2: begin
                        instr_valid  <= 1'b1;
                        opcode       <= PY_OP_LOAD_CONST;
                        arg          <= 32'b0;
                        pc           <= pc_q - 32'd2;
                        inline_const <= {lc_tag_q, lc_hi_q, imem_rdata[63:0]};
                        fsub_q       <= FS_NORMAL;
                        pc_q         <= pc_q + 1;
                    end

                    default: begin
                        fsub_q <= FS_NORMAL;
                    end

                endcase
            end
        end
    end

endmodule
