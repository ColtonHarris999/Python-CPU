`include "pycore_defs.svh"

module pycore_decode (
    input  logic        instr_valid_i,
    input  logic [7:0]  opcode_i,
    input  logic [31:0] arg_i,
    input  logic [31:0] pc_i,
    input  logic [5:0]  tos_index_i,
    input  logic [5:0]  locals_base_i,
    output logic        decoded_valid_o,
    output logic [4:0]  alu_op_o,
    output logic [6:0]  rs1_sel_o,
    output logic [6:0]  rs2_sel_o,
    output logic [6:0]  rd_sel_o,
    output logic        is_branch_o,
    output logic        is_call_o,
    output logic        is_return_o,
    // Asserted for multi-cycle container / name / const-table operations
    // handled by S_CONTAINER (bypass S_MEM and S_WB).
    output logic        is_container_o,
    output logic        push_stack_o,
    output logic        pop_stack_o,
    output logic [2:0]  mem_op_o,
    output logic        illegal_opcode_o,
    output logic [31:0] decoded_pc_o
);

    function automatic logic [4:0] decode_binary_op(input logic [7:0] subop);
        begin
            unique case (subop)
                8'd0, 8'd13:  decode_binary_op = PY_ALU_ADD;
                8'd1, 8'd14:  decode_binary_op = PY_ALU_AND;
                8'd2, 8'd15:  decode_binary_op = PY_ALU_FLOOR_DIV;
                8'd3, 8'd16:  decode_binary_op = PY_ALU_LSHIFT;
                8'd5, 8'd18:  decode_binary_op = PY_ALU_MUL;
                8'd6, 8'd19:  decode_binary_op = PY_ALU_MOD;
                8'd7, 8'd20:  decode_binary_op = PY_ALU_OR;
                8'd8, 8'd21:  decode_binary_op = PY_ALU_POWER;
                8'd9, 8'd22:  decode_binary_op = PY_ALU_RSHIFT;
                8'd10, 8'd23: decode_binary_op = PY_ALU_SUB;
                8'd11, 8'd24: decode_binary_op = PY_ALU_TRUE_DIV;
                8'd12, 8'd25: decode_binary_op = PY_ALU_XOR;
                // NB_SUBSCR (oparg=26): subscript read x[k].  Routes to the
                // S_CONTAINER multi-cycle path rather than the execute fabric.
                PY_NBARG_SUBSCR: decode_binary_op = PY_ALU_SUBSCR;
                default:      decode_binary_op = PY_ALU_ILLEGAL;
            endcase
        end
    endfunction

    // CPython 3.14 COMPARE_OP: comparison selector is oparg >> 5.
    function automatic logic [4:0] decode_compare_op(input logic [7:0] cmp);
        begin
            unique case (cmp[7:5])
                3'd0: decode_compare_op = PY_ALU_LT;
                3'd1: decode_compare_op = PY_ALU_LE;
                3'd2: decode_compare_op = PY_ALU_EQ;
                3'd3: decode_compare_op = PY_ALU_NE;
                3'd4: decode_compare_op = PY_ALU_GT;
                3'd5: decode_compare_op = PY_ALU_GE;
                default: decode_compare_op = PY_ALU_ILLEGAL;
            endcase
        end
    endfunction

    always_comb begin
        decoded_valid_o = instr_valid_i;
        alu_op_o = PY_ALU_PASS;
        rs1_sel_o = 7'b0;
        rs2_sel_o = 7'b0;
        rd_sel_o = 7'b0;
        is_branch_o = 1'b0;
        is_call_o = 1'b0;
        is_return_o = 1'b0;
        is_container_o = 1'b0;
        push_stack_o = 1'b0;
        pop_stack_o = 1'b0;
        mem_op_o = PY_MEM_NONE;
        illegal_opcode_o = 1'b0;
        decoded_pc_o = pc_i;

        unique case (opcode_i)
            PY_OP_RESUME, PY_OP_NOT_TAKEN: begin
                // NOT_TAKEN is a monitoring NOP in 3.14 branch patterns.
            end

            PY_OP_LOAD_FAST, PY_OP_LOAD_FAST_BORROW: begin
                rs1_sel_o = {1'b0, locals_base_i + arg_i[5:0]};
                rd_sel_o = {1'b0, tos_index_i};
                push_stack_o = 1'b1;
                mem_op_o = PY_MEM_LOAD_FAST;
            end

            // Combined load: arg[7:4]=first, arg[3:0]=second. Handled as a
            // two-beat container op so the image path can keep 1:1 encoding.
            PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW: begin
                is_container_o = 1'b1;
            end

            PY_OP_STORE_FAST: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                rd_sel_o = {1'b0, locals_base_i + arg_i[5:0]};
                pop_stack_o = 1'b1;
                mem_op_o = PY_MEM_STORE_FAST;
            end

            PY_OP_LOAD_SMALL_INT: begin
                rd_sel_o = {1'b0, tos_index_i};
                push_stack_o = 1'b1;
            end

            // LOAD_CONST: read co_consts[arg] via CONT_LOAD_CONST.
            PY_OP_LOAD_CONST: begin
                is_container_o = 1'b1;
            end

            // PUSH_NULL: push {PY_TAG_NULL, 0} (self_or_null sentinel).
            PY_OP_PUSH_NULL: begin
                rd_sel_o = {1'b0, tos_index_i};
                push_stack_o = 1'b1;
            end

            // TO_BOOL: convert TOS numeric to BOOL in place (net stack 0).
            PY_OP_TO_BOOL: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                rd_sel_o  = {1'b0, tos_index_i - 6'd1};
                alu_op_o  = PY_ALU_PASS;  // conversion done in core EX
            end

            // MAKE_FUNCTION: pop code / push function (≡ code). Net effect 0.
            // Verified in EXEC: trap TYPE if TOS is not CODE_OBJECT.
            PY_OP_MAKE_FUNCTION: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
            end

            PY_OP_POP_TOP, PY_OP_POP_ITER: begin
                pop_stack_o = 1'b1;
            end

            PY_OP_BINARY_OP: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd2};
                rs2_sel_o = {1'b0, tos_index_i - 6'd1};
                rd_sel_o = {1'b0, tos_index_i - 6'd2};
                alu_op_o = decode_binary_op(arg_i[7:0]);
                if (alu_op_o == PY_ALU_SUBSCR) begin
                    is_container_o = 1'b1;
                end else begin
                    pop_stack_o = 1'b1;
                    illegal_opcode_o = alu_op_o == PY_ALU_ILLEGAL;
                end
            end

            PY_OP_COMPARE_OP: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd2};
                rs2_sel_o = {1'b0, tos_index_i - 6'd1};
                rd_sel_o = {1'b0, tos_index_i - 6'd2};
                pop_stack_o = 1'b1;
                alu_op_o = decode_compare_op(arg_i[7:0]);
                illegal_opcode_o = alu_op_o == PY_ALU_ILLEGAL;
            end

            PY_OP_RETURN_VALUE: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                pop_stack_o = 1'b1;
                is_return_o = 1'b1;
                alu_op_o = PY_ALU_PASS;
            end

            PY_OP_JUMP_FORWARD, PY_OP_JUMP_BACKWARD,
            PY_OP_POP_JUMP_IF_TRUE, PY_OP_POP_JUMP_IF_FALSE: begin
                is_branch_o = 1'b1;
                if (opcode_i == PY_OP_POP_JUMP_IF_TRUE || opcode_i == PY_OP_POP_JUMP_IF_FALSE) begin
                    rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                    pop_stack_o = 1'b1;
                end
            end

            PY_OP_CALL: begin
                is_call_o = 1'b1;
            end

            // LOAD_GLOBAL / LOAD_NAME / STORE_*: multi-cycle name dict ops.
            PY_OP_LOAD_GLOBAL, PY_OP_LOAD_NAME: begin
                is_container_o = 1'b1;
            end

            PY_OP_STORE_NAME, PY_OP_STORE_GLOBAL: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_LIST: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_MAP: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_TUPLE: begin
                is_container_o = 1'b1;
            end

            PY_OP_STORE_SUBSCR: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};  // key
                rs2_sel_o = {1'b0, tos_index_i - 6'd2};  // container
                is_container_o = 1'b1;
            end

            PY_OP_MEM_LOAD_PTR: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                rd_sel_o  = {1'b0, tos_index_i - 6'd1};
                mem_op_o  = PY_MEM_LOAD_PTR;
            end

            PY_OP_MEM_STORE_PTR: begin
                rs1_sel_o = {1'b0, tos_index_i - 6'd1};
                rs2_sel_o = {1'b0, tos_index_i - 6'd2};
                pop_stack_o = 1'b1;
                mem_op_o  = PY_MEM_STORE_PTR;
            end

            default: begin
                illegal_opcode_o = 1'b1;
                alu_op_o = PY_ALU_ILLEGAL;
            end
        endcase
    end

endmodule
