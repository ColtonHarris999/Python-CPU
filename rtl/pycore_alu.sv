import pycore_types_pkg::*;

module pycore_alu #(
    parameter int ENTRY_W = 66,
    parameter int DIV_LATENCY = 8
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,
    input  logic [5:0]         cmd,
    input  logic [ENTRY_W-1:0] op_a,
    input  logic [ENTRY_W-1:0] op_b,
    output logic [ENTRY_W-1:0] result,
    output logic               done,
    output logic               stall,
    output logic               trap,
    output logic [3:0]         trap_code
);
    logic [1:0] a_tag;
    logic [1:0] b_tag;
    logic signed [63:0] a_val;
    logic signed [63:0] b_val;

    logic signed [63:0] mul_result;

    logic        div_start;
    logic        div_busy;
    logic        div_valid;
    logic        div_zero;
    logic signed [63:0] div_quotient;
    logic signed [63:0] div_remainder;

    assign a_tag = op_a[65:64];
    assign b_tag = op_b[65:64];
    assign a_val = op_a[63:0];
    assign b_val = op_b[63:0];

    pycore_mul u_mul (
        .a(a_val),
        .b(b_val),
        .result(mul_result)
    );

    pycore_div #(
        .LATENCY(DIV_LATENCY)
    ) u_div (
        .clk(clk),
        .rst_n(rst_n),
        .start(div_start),
        .dividend(a_val),
        .divisor(b_val),
        .busy(div_busy),
        .valid(div_valid),
        .div_zero(div_zero),
        .quotient(div_quotient),
        .remainder(div_remainder)
    );

    function automatic logic signed [63:0] promote_to_int(
        input logic [1:0] tag,
        input logic signed [63:0] value
    );
        begin
            if (tag == TAG_BOOL) begin
                promote_to_int = value[0] ? 64'sd1 : 64'sd0;
            end else begin
                promote_to_int = value;
            end
        end
    endfunction

    function automatic logic valid_intish_pair(input logic [1:0] t0, input logic [1:0] t1);
        begin
            valid_intish_pair = ((t0 == TAG_INT) || (t0 == TAG_BOOL)) &&
                                ((t1 == TAG_INT) || (t1 == TAG_BOOL));
        end
    endfunction

    always_comb begin
        result    = {TAG_UNINIT, 64'd0};
        done      = 1'b1;
        stall     = 1'b0;
        trap      = 1'b0;
        trap_code = TRAP_NONE;
        div_start = 1'b0;

        unique case (cmd)
            ALU_NOP: begin
                result = op_a;
            end

            ALU_ADD, ALU_SUB, ALU_LSHIFT, ALU_RSHIFT,
            ALU_XOR: begin
                if (valid_intish_pair(a_tag, b_tag)) begin
                    unique case (cmd)
                        ALU_ADD: begin
                            result = {TAG_INT, promote_to_int(a_tag, a_val) + promote_to_int(b_tag, b_val)};
                        end
                        ALU_SUB: begin
                            result = {TAG_INT, promote_to_int(a_tag, a_val) - promote_to_int(b_tag, b_val)};
                        end
                        ALU_LSHIFT: begin
                            if (promote_to_int(b_tag, b_val) < 0) begin
                                trap = 1'b1;
                                trap_code = TRAP_TYPE;
                            end else begin
                                result = {TAG_INT, promote_to_int(a_tag, a_val) <<< promote_to_int(b_tag, b_val)};
                            end
                        end
                        ALU_RSHIFT: begin
                            if (promote_to_int(b_tag, b_val) < 0) begin
                                trap = 1'b1;
                                trap_code = TRAP_TYPE;
                            end else begin
                                result = {TAG_INT, promote_to_int(a_tag, a_val) >>> promote_to_int(b_tag, b_val)};
                            end
                        end
                        default: begin
                            result = {TAG_INT, promote_to_int(a_tag, a_val) ^ promote_to_int(b_tag, b_val)};
                        end
                    endcase
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_MUL: begin
                if (valid_intish_pair(a_tag, b_tag)) begin
                    result = {TAG_INT, mul_result};
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_DIV, ALU_MOD: begin
                if (!valid_intish_pair(a_tag, b_tag)) begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end else if (start && !div_busy && !div_valid) begin
                    div_start = 1'b1;
                    done = 1'b0;
                    stall = 1'b1;
                end else if (div_busy) begin
                    done = 1'b0;
                    stall = 1'b1;
                end else if (div_valid) begin
                    if (div_zero) begin
                        trap = 1'b1;
                        trap_code = TRAP_DIV_ZERO;
                    end else if (cmd == ALU_DIV) begin
                        result = {TAG_INT, div_quotient};
                    end else begin
                        result = {TAG_INT, div_remainder};
                    end
                end else begin
                    done = 1'b0;
                end
            end

            ALU_AND, ALU_OR: begin
                if ((a_tag == TAG_BOOL) && (b_tag == TAG_BOOL)) begin
                    if (cmd == ALU_AND) begin
                        result = {TAG_BOOL, {63'd0, a_val[0] & b_val[0]}};
                    end else begin
                        result = {TAG_BOOL, {63'd0, a_val[0] | b_val[0]}};
                    end
                end else if (valid_intish_pair(a_tag, b_tag)) begin
                    if (cmd == ALU_AND) begin
                        result = {TAG_INT, promote_to_int(a_tag, a_val) & promote_to_int(b_tag, b_val)};
                    end else begin
                        result = {TAG_INT, promote_to_int(a_tag, a_val) | promote_to_int(b_tag, b_val)};
                    end
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_CMP_EQ, ALU_CMP_NE, ALU_CMP_LT, ALU_CMP_LE, ALU_CMP_GT, ALU_CMP_GE: begin
                logic signed [63:0] lhs;
                logic signed [63:0] rhs;
                logic cmp;
                lhs = promote_to_int(a_tag, a_val);
                rhs = promote_to_int(b_tag, b_val);
                cmp = 1'b0;
                if (valid_intish_pair(a_tag, b_tag)) begin
                    unique case (cmd)
                        ALU_CMP_EQ: cmp = (lhs == rhs);
                        ALU_CMP_NE: cmp = (lhs != rhs);
                        ALU_CMP_LT: cmp = (lhs < rhs);
                        ALU_CMP_LE: cmp = (lhs <= rhs);
                        ALU_CMP_GT: cmp = (lhs > rhs);
                        default:    cmp = (lhs >= rhs);
                    endcase
                    result = {TAG_BOOL, {63'd0, cmp}};
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_UNARY_NOT: begin
                if (a_tag == TAG_BOOL) begin
                    result = {TAG_BOOL, {63'd0, ~a_val[0]}};
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_UNARY_NEG: begin
                if (a_tag == TAG_INT) begin
                    result = {TAG_INT, -a_val};
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            ALU_UNARY_POS: begin
                if (a_tag == TAG_REF) begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end else if (a_tag == TAG_BOOL) begin
                    result = {TAG_INT, promote_to_int(a_tag, a_val)};
                end else begin
                    result = op_a;
                end
            end

            ALU_UNARY_INV: begin
                if (a_tag == TAG_INT) begin
                    result = {TAG_INT, ~a_val};
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            default: begin
                trap = 1'b1;
                trap_code = TRAP_ILLEGAL;
            end
        endcase
    end
endmodule
