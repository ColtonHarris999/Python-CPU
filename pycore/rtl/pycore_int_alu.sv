`include "pycore_defs.svh"

module pycore_int_alu (
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    input  logic [4:0]  op_i,
    output logic [63:0] result_o,
    output logic        zero_flag_o,
    // The result does not fit the signed 64-bit INT (+ - unary - <<).
    output logic        overflow_flag_o,
    // Operand outside the operation's domain: negative shift count.
    output logic        value_error_o
);

    logic signed [63:0] a_s;
    logic signed [63:0] b_s;
    logic signed [64:0] add_ext;
    logic signed [64:0] sub_ext;
    logic signed [63:0] sra;
    logic signed [63:0] sll;
    logic signed [63:0] sll_back;
    logic cmp_result;

    assign a_s = op_a_i;
    assign b_s = op_b_i;
    assign add_ext = {a_s[63], a_s} + {b_s[63], b_s};
    assign sub_ext = {a_s[63], a_s} - {b_s[63], b_s};
    // Arithmetic shift in its own signed assignment: inside the unsigned
    // ternary below `>>>` would silently degrade to a logical shift.
    assign sra = a_s >>> op_b_i[5:0];
    assign sll = a_s <<< op_b_i[5:0];
    // Shifting back recovers a only when no significant bit (sign included)
    // was lost: that is the Python big-int overflow check for a << b.
    assign sll_back = sll >>> op_b_i[5:0];

    always_comb begin
        result_o = 64'b0;
        cmp_result = 1'b0;
        overflow_flag_o = 1'b0;
        value_error_o = 1'b0;

        unique case (op_i)
            PY_ALU_ADD: begin
                result_o = op_a_i + op_b_i;
                overflow_flag_o = add_ext[64] != add_ext[63];
            end
            PY_ALU_SUB: begin
                result_o = op_a_i - op_b_i;
                overflow_flag_o = sub_ext[64] != sub_ext[63];
            end
            PY_ALU_NEG: begin
                result_o = -op_a_i;
                overflow_flag_o = op_a_i == 64'h8000_0000_0000_0000;
            end
            PY_ALU_POS, PY_ALU_PASS: begin
                result_o = op_a_i;
            end
            PY_ALU_INVERT: begin
                result_o = ~op_a_i;
            end
            PY_ALU_LSHIFT: begin
                // b < 0: ValueError. b >= 64: only 0 stays representable.
                value_error_o = b_s < 0;
                if (op_b_i[63:6] != 58'b0) begin
                    result_o = 64'b0;
                    overflow_flag_o = !value_error_o && (op_a_i != 64'b0);
                end else begin
                    result_o = sll;
                    overflow_flag_o = !value_error_o && (sll_back != a_s);
                end
            end
            PY_ALU_RSHIFT: begin
                value_error_o = b_s < 0;
                result_o = (op_b_i[63:6] != 58'b0) ? (a_s[63] ? 64'hffff_ffff_ffff_ffff : 64'b0) :
                                                     sra;
            end
            PY_ALU_AND: begin
                result_o = op_a_i & op_b_i;
            end
            PY_ALU_OR: begin
                result_o = op_a_i | op_b_i;
            end
            PY_ALU_XOR: begin
                result_o = op_a_i ^ op_b_i;
            end
            PY_ALU_NOT: begin
                result_o = {63'b0, op_a_i == 64'b0};
            end
            PY_ALU_EQ: begin
                cmp_result = op_a_i == op_b_i;
                result_o = {63'b0, cmp_result};
            end
            PY_ALU_NE: begin
                cmp_result = op_a_i != op_b_i;
                result_o = {63'b0, cmp_result};
            end
            PY_ALU_LT: begin
                cmp_result = a_s < b_s;
                result_o = {63'b0, cmp_result};
            end
            PY_ALU_LE: begin
                cmp_result = a_s <= b_s;
                result_o = {63'b0, cmp_result};
            end
            PY_ALU_GT: begin
                cmp_result = a_s > b_s;
                result_o = {63'b0, cmp_result};
            end
            PY_ALU_GE: begin
                cmp_result = a_s >= b_s;
                result_o = {63'b0, cmp_result};
            end
            default: begin
                result_o = 64'b0;
            end
        endcase
    end

    assign zero_flag_o = (result_o == 64'b0);

endmodule
