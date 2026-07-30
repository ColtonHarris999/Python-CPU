`include "pycore_defs.svh"

module pycore_tag_decode (
    input  logic [3:0] rs1_tag_i,
    input  logic [3:0] rs2_tag_i,
    input  logic [4:0] alu_op_i,
    output logic [2:0] exec_unit_sel_o,
    output logic       promote_rs1_o,
    output logic       promote_rs2_o,
    output logic [2:0] promote_rs1_mode_o,
    output logic [2:0] promote_rs2_mode_o,
    output logic [3:0] result_tag_o,
    output logic       is_trap_o,
    output logic [4:0] trap_code_o
);

    function automatic logic is_compare(input logic [4:0] op);
        begin
            is_compare = (op == PY_ALU_EQ) || (op == PY_ALU_NE) || (op == PY_ALU_LT) ||
                         (op == PY_ALU_LE) || (op == PY_ALU_GT) || (op == PY_ALU_GE);
        end
    endfunction

    function automatic logic is_binary_arith(input logic [4:0] op);
        begin
            is_binary_arith = (op == PY_ALU_ADD) || (op == PY_ALU_SUB) ||
                              (op == PY_ALU_MUL) || (op == PY_ALU_FLOOR_DIV) ||
                              (op == PY_ALU_TRUE_DIV) || (op == PY_ALU_MOD) ||
                              (op == PY_ALU_POWER);
        end
    endfunction

`define PYCORE_FORCE_TRAP(_code) \
    begin \
        exec_unit_sel_o = PY_EXEC_TRAP; \
        result_tag_o = PY_TAG_OBJECT; \
        is_trap_o = 1'b1; \
        trap_code_o = (_code); \
    end

`define PYCORE_ROUTE_FLOAT_BINARY(_out_tag) \
    begin \
        exec_unit_sel_o = PY_EXEC_FLOAT; \
        result_tag_o = (_out_tag); \
        if (rs1_tag_i == PY_TAG_INT) begin \
            promote_rs1_o = 1'b1; \
            promote_rs1_mode_o = PY_PROMOTE_INT_TO_FLOAT; \
        end else if (rs1_tag_i == PY_TAG_BOOL) begin \
            promote_rs1_o = 1'b1; \
            promote_rs1_mode_o = PY_PROMOTE_BOOL_TO_FLOAT; \
        end \
        if (rs2_tag_i == PY_TAG_INT) begin \
            promote_rs2_o = 1'b1; \
            promote_rs2_mode_o = PY_PROMOTE_INT_TO_FLOAT; \
        end else if (rs2_tag_i == PY_TAG_BOOL) begin \
            promote_rs2_o = 1'b1; \
            promote_rs2_mode_o = PY_PROMOTE_BOOL_TO_FLOAT; \
        end \
    end


`define PYCORE_ROUTE_COMPLEX_BINARY(_out_tag) \
    begin \
        exec_unit_sel_o = PY_EXEC_COMPLEX; \
        result_tag_o = (_out_tag); \
    end
`define PYCORE_ROUTE_INT_BINARY(_out_tag) \
    begin \
        exec_unit_sel_o = PY_EXEC_INT; \
        result_tag_o = (_out_tag); \
        if (rs1_tag_i == PY_TAG_BOOL) begin \
            promote_rs1_o = 1'b1; \
            promote_rs1_mode_o = PY_PROMOTE_BOOL_TO_INT; \
        end \
        if (rs2_tag_i == PY_TAG_BOOL) begin \
            promote_rs2_o = 1'b1; \
            promote_rs2_mode_o = PY_PROMOTE_BOOL_TO_INT; \
        end \
    end

    always_comb begin
        exec_unit_sel_o = PY_EXEC_TRAP;
        promote_rs1_o = 1'b0;
        promote_rs2_o = 1'b0;
        promote_rs1_mode_o = PY_PROMOTE_NONE;
        promote_rs2_mode_o = PY_PROMOTE_NONE;
        result_tag_o = PY_TAG_OBJECT;
        is_trap_o = 1'b0;
        trap_code_o = PY_TRAP_NONE;

        if ((alu_op_i == PY_ALU_ILLEGAL) || (alu_op_i > PY_ALU_PASS)) begin
            `PYCORE_FORCE_TRAP(PY_TRAP_ILLEGAL_OPCODE)
        end else if (pycore_is_trapping_tag(rs1_tag_i) &&
                     !(alu_op_i == PY_ALU_PASS && rs1_tag_i != PY_TAG_UNINIT)) begin
            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
        end else if ((is_binary_arith(alu_op_i) || is_compare(alu_op_i) ||
                      alu_op_i == PY_ALU_LSHIFT || alu_op_i == PY_ALU_RSHIFT ||
                      alu_op_i == PY_ALU_AND || alu_op_i == PY_ALU_OR || alu_op_i == PY_ALU_XOR) &&
                     pycore_is_trapping_tag(rs2_tag_i)) begin
            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
        end else begin
            unique case (alu_op_i)
                PY_ALU_PASS: begin
                    exec_unit_sel_o = PY_EXEC_INT;
                    result_tag_o = rs1_tag_i;
                end

                PY_ALU_NEG, PY_ALU_POS: begin
                    if (rs1_tag_i == PY_TAG_INT) begin
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_INT;
                    end else if (rs1_tag_i == PY_TAG_BOOL) begin
                        // BOOL promotes to INT (−True == −1), matching CPython.
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_INT;
                        promote_rs1_o = 1'b1;
                        promote_rs1_mode_o = PY_PROMOTE_BOOL_TO_INT;
                    end else if (rs1_tag_i == PY_TAG_FLOAT) begin
                        exec_unit_sel_o = PY_EXEC_FLOAT;
                        result_tag_o = PY_TAG_FLOAT;
                    end else if (rs1_tag_i == PY_TAG_COMPLEX) begin
                        exec_unit_sel_o = PY_EXEC_COMPLEX;
                        result_tag_o = PY_TAG_COMPLEX;
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_INVERT: begin
                    // INT/BOOL only; BOOL promotes to INT (~True == −2).
                    // FLOAT and other tags → TYPE.
                    if (rs1_tag_i == PY_TAG_INT) begin
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_INT;
                    end else if (rs1_tag_i == PY_TAG_BOOL) begin
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_INT;
                        promote_rs1_o = 1'b1;
                        promote_rs1_mode_o = PY_PROMOTE_BOOL_TO_INT;
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_NOT: begin
                    if (rs1_tag_i == PY_TAG_COMPLEX) begin
                        exec_unit_sel_o = PY_EXEC_COMPLEX;
                        result_tag_o = PY_TAG_BOOL;
                    end else if (pycore_is_real_numeric_tag(rs1_tag_i)) begin
                        exec_unit_sel_o = (rs1_tag_i == PY_TAG_FLOAT) ? PY_EXEC_FLOAT : PY_EXEC_BOOL;
                        result_tag_o = PY_TAG_BOOL;
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_TRUE_DIV: begin
                    if ((rs1_tag_i == PY_TAG_COMPLEX) || (rs2_tag_i == PY_TAG_COMPLEX)) begin
                        if (pycore_is_numeric_tag(rs1_tag_i) && pycore_is_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_COMPLEX_BINARY(PY_TAG_COMPLEX)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                                 pycore_is_real_numeric_tag(rs2_tag_i)) begin
                        `PYCORE_ROUTE_FLOAT_BINARY(PY_TAG_FLOAT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_ADD: begin
                    if (pycore_is_string_tag(rs1_tag_i) && pycore_is_string_tag(rs2_tag_i)) begin
                        // String concatenation runs in pycore_exec's string path.
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_SHORT_STR;
                    end else if ((rs1_tag_i == PY_TAG_COMPLEX) || (rs2_tag_i == PY_TAG_COMPLEX)) begin
                        if (pycore_is_numeric_tag(rs1_tag_i) && pycore_is_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_COMPLEX_BINARY(PY_TAG_COMPLEX)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_FLOAT || rs2_tag_i == PY_TAG_FLOAT) begin
                        if (pycore_is_numeric_tag(rs1_tag_i) && pycore_is_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_FLOAT_BINARY(PY_TAG_FLOAT)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_BOOL && rs2_tag_i == PY_TAG_BOOL) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else if (pycore_is_numeric_tag(rs1_tag_i) && pycore_is_numeric_tag(rs2_tag_i)) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_SUB, PY_ALU_MUL: begin
                    if ((rs1_tag_i == PY_TAG_COMPLEX) || (rs2_tag_i == PY_TAG_COMPLEX)) begin
                        if (pycore_is_numeric_tag(rs1_tag_i) && pycore_is_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_COMPLEX_BINARY(PY_TAG_COMPLEX)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_FLOAT || rs2_tag_i == PY_TAG_FLOAT) begin
                        if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                            pycore_is_real_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_FLOAT_BINARY(PY_TAG_FLOAT)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_BOOL && rs2_tag_i == PY_TAG_BOOL) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                                 pycore_is_real_numeric_tag(rs2_tag_i)) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_FLOOR_DIV, PY_ALU_MOD, PY_ALU_POWER: begin
                    if ((rs1_tag_i == PY_TAG_COMPLEX) || (rs2_tag_i == PY_TAG_COMPLEX)) begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end else if (rs1_tag_i == PY_TAG_FLOAT || rs2_tag_i == PY_TAG_FLOAT) begin
                        if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                            pycore_is_real_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_FLOAT_BINARY(PY_TAG_FLOAT)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_BOOL && rs2_tag_i == PY_TAG_BOOL) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                                 pycore_is_real_numeric_tag(rs2_tag_i)) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_LSHIFT, PY_ALU_RSHIFT: begin
                    if (rs1_tag_i == PY_TAG_INT && rs2_tag_i == PY_TAG_INT) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                PY_ALU_AND, PY_ALU_OR, PY_ALU_XOR: begin
                    if (rs1_tag_i == PY_TAG_BOOL && rs2_tag_i == PY_TAG_BOOL) begin
                        exec_unit_sel_o = PY_EXEC_BOOL;
                        result_tag_o = PY_TAG_BOOL;
                    end else if ((rs1_tag_i == PY_TAG_INT || rs1_tag_i == PY_TAG_BOOL) &&
                                 (rs2_tag_i == PY_TAG_INT || rs2_tag_i == PY_TAG_BOOL)) begin
                        `PYCORE_ROUTE_INT_BINARY(PY_TAG_INT)
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                // Native COMPARE_OP: numeric pairs + same-tag SHORT_STR/LONG_STR
                // equality (==/!=). Ordering on strings and all other tags trap.
                // LONG_STR uses descriptor equality (see bytecode_support.md).
                PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_LE, PY_ALU_GT, PY_ALU_GE: begin
                    if ((rs1_tag_i == PY_TAG_COMPLEX) || (rs2_tag_i == PY_TAG_COMPLEX)) begin
                        if ((alu_op_i == PY_ALU_EQ || alu_op_i == PY_ALU_NE) &&
                            pycore_is_numeric_tag(rs1_tag_i) &&
                            pycore_is_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_COMPLEX_BINARY(PY_TAG_BOOL)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if (rs1_tag_i == PY_TAG_FLOAT || rs2_tag_i == PY_TAG_FLOAT) begin
                        if (pycore_is_real_numeric_tag(rs1_tag_i) &&
                            pycore_is_real_numeric_tag(rs2_tag_i)) begin
                            `PYCORE_ROUTE_FLOAT_BINARY(PY_TAG_BOOL)
                        end else begin
                            `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                        end
                    end else if ((rs1_tag_i == PY_TAG_BOOL || rs1_tag_i == PY_TAG_INT) &&
                                 (rs2_tag_i == PY_TAG_BOOL || rs2_tag_i == PY_TAG_INT)) begin
                        if (rs1_tag_i == PY_TAG_BOOL && rs2_tag_i == PY_TAG_BOOL &&
                            (alu_op_i == PY_ALU_EQ || alu_op_i == PY_ALU_NE)) begin
                            exec_unit_sel_o = PY_EXEC_BOOL;
                            result_tag_o = PY_TAG_BOOL;
                        end else begin
                            `PYCORE_ROUTE_INT_BINARY(PY_TAG_BOOL)
                        end
                    end else if ((alu_op_i == PY_ALU_EQ || alu_op_i == PY_ALU_NE) &&
                                 (rs1_tag_i == rs2_tag_i) &&
                                 pycore_is_string_tag(rs1_tag_i)) begin
                        // Equality only; result built from full 128-bit value
                        // compare in pycore_exec (string_cmp path).
                        exec_unit_sel_o = PY_EXEC_INT;
                        result_tag_o = PY_TAG_BOOL;
                    end else begin
                        `PYCORE_FORCE_TRAP(PY_TRAP_TYPE)
                    end
                end

                default: begin
                    `PYCORE_FORCE_TRAP(PY_TRAP_ILLEGAL_OPCODE)
                end
            endcase
        end
    end

endmodule

`undef PYCORE_FORCE_TRAP
`undef PYCORE_ROUTE_FLOAT_BINARY
`undef PYCORE_ROUTE_COMPLEX_BINARY
`undef PYCORE_ROUTE_INT_BINARY
