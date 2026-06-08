`include "pycore_defs.svh"

module pycore_int_alu (
    input  logic [63:0] op_a,
    input  logic [63:0] op_b,
    input  logic [4:0]  op,
    output logic [63:0] result,
    output logic        zero_flag,
    output logic        overflow_flag
);

    logic signed [63:0] a_s;
    logic signed [63:0] b_s;
    logic signed [64:0] add_ext;
    logic signed [64:0] sub_ext;
    logic cmp_result;

    assign a_s = op_a;
    assign b_s = op_b;
    assign add_ext = {a_s[63], a_s} + {b_s[63], b_s};
    assign sub_ext = {a_s[63], a_s} - {b_s[63], b_s};

    always_comb begin
        result = 64'b0;
        cmp_result = 1'b0;
        overflow_flag = 1'b0;

        unique case (op)
            PY_ALU_ADD: begin
                result = op_a + op_b;
                overflow_flag = add_ext[64] != add_ext[63];
            end
            PY_ALU_SUB: begin
                result = op_a - op_b;
                overflow_flag = sub_ext[64] != sub_ext[63];
            end
            PY_ALU_NEG: begin
                result = -op_a;
                overflow_flag = op_a == 64'h8000_0000_0000_0000;
            end
            PY_ALU_POS, PY_ALU_PASS: begin
                result = op_a;
            end
            PY_ALU_INVERT: begin
                result = ~op_a;
            end
            PY_ALU_LSHIFT: begin
                result = (b_s < 0) ? 64'b0 :
                         (op_b[63:6] != 58'b0 ? 64'b0 : (op_a <<< op_b[5:0]));
            end
            PY_ALU_RSHIFT: begin
                result = (b_s < 0) ? 64'b0 :
                         (op_b[63:6] != 58'b0 ? (a_s[63] ? 64'hffff_ffff_ffff_ffff : 64'b0) :
                                                 (a_s >>> op_b[5:0]));
            end
            PY_ALU_AND: begin
                result = op_a & op_b;
            end
            PY_ALU_OR: begin
                result = op_a | op_b;
            end
            PY_ALU_XOR: begin
                result = op_a ^ op_b;
            end
            PY_ALU_NOT: begin
                result = {63'b0, op_a == 64'b0};
            end
            PY_ALU_EQ: begin
                cmp_result = op_a == op_b;
                result = {63'b0, cmp_result};
            end
            PY_ALU_NE: begin
                cmp_result = op_a != op_b;
                result = {63'b0, cmp_result};
            end
            PY_ALU_LT: begin
                cmp_result = a_s < b_s;
                result = {63'b0, cmp_result};
            end
            PY_ALU_LE: begin
                cmp_result = a_s <= b_s;
                result = {63'b0, cmp_result};
            end
            PY_ALU_GT: begin
                cmp_result = a_s > b_s;
                result = {63'b0, cmp_result};
            end
            PY_ALU_GE: begin
                cmp_result = a_s >= b_s;
                result = {63'b0, cmp_result};
            end
            default: begin
                result = 64'b0;
            end
        endcase
    end

    assign zero_flag = (result == 64'b0);

endmodule
