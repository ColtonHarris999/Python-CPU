import pycore_types_pkg::*;

module pycore_decode (
    input  logic [7:0]  opcode,
    input  logic [31:0] arg,
    output logic        valid_opcode,
    output logic        is_load_const,
    output logic        is_load_small_int,
    output logic        is_load_fast,
    output logic        is_store_fast,
    output logic        is_pop_top,
    output logic        is_copy,
    output logic        is_swap,
    output logic        is_branch,
    output logic        is_return,
    output logic        is_call,
    output logic        is_unary,
    output logic        is_binary,
    output logic        is_compare,
    output logic [5:0]  alu_cmd
);
    always_comb begin
        valid_opcode = 1'b1;
        is_load_const = 1'b0;
        is_load_small_int = 1'b0;
        is_load_fast  = 1'b0;
        is_store_fast = 1'b0;
        is_pop_top    = 1'b0;
        is_copy       = 1'b0;
        is_swap       = 1'b0;
        is_branch     = 1'b0;
        is_return     = 1'b0;
        is_call       = 1'b0;
        is_unary      = 1'b0;
        is_binary     = 1'b0;
        is_compare    = 1'b0;
        alu_cmd       = ALU_NOP;

        unique case (opcode)
            OP_RESUME, OP_NOP: begin
            end
            OP_LOAD_CONST: begin
                is_load_const = 1'b1;
            end
            OP_LOAD_SMALL_INT: begin
                is_load_small_int = 1'b1;
            end
            OP_LOAD_FAST: begin
                is_load_fast = 1'b1;
            end
            OP_STORE_FAST: begin
                is_store_fast = 1'b1;
            end
            OP_POP_TOP: begin
                is_pop_top = 1'b1;
            end
            OP_COPY: begin
                is_copy = 1'b1;
            end
            OP_SWAP: begin
                is_swap = 1'b1;
            end
            OP_JUMP_FORWARD, OP_JUMP_BACKWARD,
            OP_POP_JUMP_FORWARD_IF_TRUE, OP_POP_JUMP_FORWARD_IF_FALSE,
            OP_POP_JUMP_BACKWARD_IF_TRUE, OP_POP_JUMP_BACKWARD_IF_FALSE,
            OP_JUMP_IF_TRUE_OR_POP, OP_JUMP_IF_FALSE_OR_POP: begin
                is_branch = 1'b1;
            end
            OP_RETURN_VALUE: begin
                is_return = 1'b1;
            end
            OP_CALL: begin
                is_call = 1'b1;
            end
            OP_UNARY_NOT: begin
                is_unary = 1'b1;
                alu_cmd = ALU_UNARY_NOT;
            end
            OP_UNARY_NEGATIVE: begin
                is_unary = 1'b1;
                alu_cmd = ALU_UNARY_NEG;
            end
            OP_UNARY_POSITIVE: begin
                is_unary = 1'b1;
                alu_cmd = ALU_UNARY_POS;
            end
            OP_UNARY_INVERT: begin
                is_unary = 1'b1;
                alu_cmd = ALU_UNARY_INV;
            end
            OP_BINARY_OP: begin
                is_binary = 1'b1;
                unique case (arg[7:0])
                    NB_ADD, NB_INPLACE_ADD: alu_cmd = ALU_ADD;
                    NB_SUBTRACT, NB_INPLACE_SUBTRACT: alu_cmd = ALU_SUB;
                    NB_MULTIPLY, NB_INPLACE_MULTIPLY: alu_cmd = ALU_MUL;
                    NB_FLOOR_DIVIDE, NB_INPLACE_FLOOR_DIVIDE: alu_cmd = ALU_DIV;
                    NB_REMAINDER, NB_INPLACE_REMAINDER: alu_cmd = ALU_MOD;
                    NB_LSHIFT, NB_INPLACE_LSHIFT: alu_cmd = ALU_LSHIFT;
                    NB_RSHIFT, NB_INPLACE_RSHIFT: alu_cmd = ALU_RSHIFT;
                    NB_AND, NB_INPLACE_AND: alu_cmd = ALU_AND;
                    NB_OR, NB_INPLACE_OR: alu_cmd = ALU_OR;
                    NB_XOR, NB_INPLACE_XOR: alu_cmd = ALU_XOR;
                    default: begin
                        valid_opcode = 1'b0;
                    end
                endcase
            end
            OP_COMPARE_OP: begin
                is_compare = 1'b1;
                unique case (arg[7:0])
                    8'd2: alu_cmd = ALU_CMP_EQ; // ==
                    8'd3: alu_cmd = ALU_CMP_NE; // !=
                    8'd0: alu_cmd = ALU_CMP_LT; // <
                    8'd1: alu_cmd = ALU_CMP_LE; // <=
                    8'd4: alu_cmd = ALU_CMP_GT; // >
                    8'd5: alu_cmd = ALU_CMP_GE; // >=
                    default: begin
                        valid_opcode = 1'b0;
                    end
                endcase
            end
            default: begin
                valid_opcode = 1'b0;
            end
        endcase
    end
endmodule
