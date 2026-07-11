`include "pycore_defs.svh"

// Instruction fetch as an imem master. Each instruction is a 64-bit slot; the
// fetch unit drives a byte address (pc_o << 3) and consumes the registered read
// data one cycle later via the req/ack handshake. EXTENDED_ARG folding and CACHE
// skipping are preserved. There is no combinational use of imem_rdata_i.
//
// LOAD_CONST is a variable-length instruction that spans 3 consecutive imem
// slots. The first slot carries the opcode_o and the 4-bit tag in bits [63:60];
// the second and third slots carry value[127:64] and value[63:0] respectively.
// The fetch unit transparently assembles all three reads before asserting
// instr_valid_o, so the rest of the pipeline sees a single-cycle LOAD_CONST
// completion carrying the full 132-bit tagged constant in inline_const_o.
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
    output logic [31:0]           pc_o,
    // Inline constant assembled from the three LOAD_CONST imem slots.
    // Valid only when instr_valid_o is high and opcode_o == PY_OP_LOAD_CONST.
    output logic [PYCORE_ENTRY_WIDTH-1:0] inline_const_o
);

    // Sub-states for the three-slot LOAD_CONST fetch sequence.
    localparam logic [1:0] FS_NORMAL   = 2'd0;  // standard single-slot fetch
    localparam logic [1:0] FS_CONST_W1 = 2'd1;  // reading value[127:64]
    localparam logic [1:0] FS_CONST_W2 = 2'd2;  // reading value[63:0]

    logic [31:0] pc_r;
    logic [31:0] arg_prefix_r;
    logic        have_prefix_r;
    logic        awaiting_r;    // a request is outstanding, ack expected next cycle

    // Current and next fetch FSM state for the LOAD_CONST multi-word sequence.
    logic [1:0]  fetch_state_r;
    logic [1:0]  fetch_state_next;

    logic [3:0]  lc_tag_r;     // tag[3:0] captured from LOAD_CONST slot 0 bits[63:60]
    logic [63:0] lc_hi_r;      // value[127:64] captured from LOAD_CONST slot 1

    // Issue a fetch only when not stalled and not already waiting on an ack.
    assign imem_req_o   = !stall_i && !awaiting_r && rst_n_i;
    assign imem_we_o    = 1'b0;
    assign imem_wdata_o = '0;
    assign imem_addr_o  = {pc_r[ADDR_WIDTH-4:0], 3'b000};  // pc_r << 3 (8-byte slots)

    // --------------------------------------------------------
    // Next-state combinational logic for the fetch sub-FSM.
    // fetch_state_r is current; fetch_state_next is computed
    // each cycle and registered on the next rising edge.
    // --------------------------------------------------------
    always_comb begin
        fetch_state_next = fetch_state_r;  // default: hold current state

        if (!stall_i) begin
            if (flush_i || branch_taken_i) begin
                fetch_state_next = FS_NORMAL;
            end else if (awaiting_r && imem_ack_i) begin
                unique case (fetch_state_r)
                    FS_NORMAL: begin
                        // Transition to FS_CONST_W1 only for LOAD_CONST; all
                        // other opcodes (including CACHE/EXTENDED_ARG) stay in
                        // FS_NORMAL after the single-slot fetch completes.
                        if (imem_rdata_i[7:0] == PY_OP_LOAD_CONST)
                            fetch_state_next = FS_CONST_W1;
                        else
                            fetch_state_next = FS_NORMAL;
                    end
                    FS_CONST_W1: fetch_state_next = FS_CONST_W2;
                    FS_CONST_W2: fetch_state_next = FS_NORMAL;
                    default:     fetch_state_next = FS_NORMAL;
                endcase
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [7:0]  fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;

        if (!rst_n_i) begin
            pc_r            <= 32'b0;
            arg_prefix_r    <= 32'b0;
            have_prefix_r   <= 1'b0;
            awaiting_r      <= 1'b0;
            fetch_state_r   <= FS_NORMAL;
            lc_tag_r        <= 4'b0;
            lc_hi_r         <= 64'b0;
            instr_valid_o   <= 1'b0;
            opcode_o        <= 8'b0;
            arg_o           <= 32'b0;
            pc_o            <= 32'b0;
            inline_const_o  <= '0;
        end else begin
            fetch_state_r <= fetch_state_next;  // register next state

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

                    unique case (fetch_state_r)

                        // ----------------------------------------------------------
                        // FS_NORMAL: read a standard 1-slot instruction (or the first
                        // slot of a LOAD_CONST 3-slot sequence).
                        // ----------------------------------------------------------
                        FS_NORMAL: begin
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

                            end else if (fetched_opcode == PY_OP_LOAD_CONST) begin
                                // LOAD_CONST slot 0: tag lives in bits [63:60].
                                // fetch_state_next = FS_CONST_W1 (set in always_comb).
                                lc_tag_r      <= imem_rdata_i[63:60];
                                have_prefix_r <= 1'b0;
                                arg_prefix_r  <= 32'b0;
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

                        // ----------------------------------------------------------
                        // FS_CONST_W1: second slot of LOAD_CONST holds value[127:64].
                        // ----------------------------------------------------------
                        FS_CONST_W1: begin
                            lc_hi_r <= imem_rdata_i[63:0];
                            // fetch_state_next = FS_CONST_W2 (set in always_comb)
                            pc_r    <= pc_r + 1;
                        end

                        // ----------------------------------------------------------
                        // FS_CONST_W2: third slot holds value[63:0]. Assemble the
                        // complete 132-bit tagged entry and present the instruction.
                        // The reported PC is the slot address of the first word (word 0),
                        // which is two slots behind the current pc_r.
                        // ----------------------------------------------------------
                        FS_CONST_W2: begin
                            instr_valid_o  <= 1'b1;
                            opcode_o       <= PY_OP_LOAD_CONST;
                            arg_o          <= 32'b0;
                            pc_o           <= pc_r - 32'd2;
                            inline_const_o <= {lc_tag_r, lc_hi_r, imem_rdata_i[63:0]};
                            // fetch_state_next = FS_NORMAL (set in always_comb)
                            pc_r           <= pc_r + 1;
                        end

                        default: ;  // fetch_state_next = FS_NORMAL (set in always_comb)

                    endcase
                end
            end
        end
    end

endmodule
