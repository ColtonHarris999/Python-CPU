`include "pycore_defs.svh"

module pycore_tag_decode (
    input  logic [2:0] rs1_tag,
    input  logic [2:0] rs2_tag,
    input  logic [4:0] alu_op,
    output logic [1:0] exec_unit_sel,
    output logic       promote_rs1,
    output logic       promote_rs2,
    output logic [1:0] promote_rs1_mode,
    output logic [1:0] promote_rs2_mode,
    output logic [2:0] result_tag,
    output logic       is_trap,
    output logic [3:0] trap_code
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

    task automatic force_trap(input logic [3:0] code);
        begin
            exec_unit_sel = PY_EXEC_TRAP;
            result_tag = PY_TAG_OBJECT;
            is_trap = 1'b1;
            trap_code = code;
        end
    endtask

    task automatic route_float_binary(input logic [2:0] out_tag);
        begin
            exec_unit_sel = PY_EXEC_FLOAT;
            result_tag = out_tag;
            if (rs1_tag == PY_TAG_INT) begin
                promote_rs1 = 1'b1;
                promote_rs1_mode = PY_PROMOTE_INT_TO_FLOAT;
            end else if (rs1_tag == PY_TAG_BOOL) begin
                promote_rs1 = 1'b1;
                promote_rs1_mode = PY_PROMOTE_BOOL_TO_FLOAT;
            end
            if (rs2_tag == PY_TAG_INT) begin
                promote_rs2 = 1'b1;
                promote_rs2_mode = PY_PROMOTE_INT_TO_FLOAT;
            end else if (rs2_tag == PY_TAG_BOOL) begin
                promote_rs2 = 1'b1;
                promote_rs2_mode = PY_PROMOTE_BOOL_TO_FLOAT;
            end
        end
    endtask

    task automatic route_int_binary(input logic [2:0] out_tag);
        begin
            exec_unit_sel = PY_EXEC_INT;
            result_tag = out_tag;
            if (rs1_tag == PY_TAG_BOOL) begin
                promote_rs1 = 1'b1;
                promote_rs1_mode = PY_PROMOTE_BOOL_TO_INT;
            end
            if (rs2_tag == PY_TAG_BOOL) begin
                promote_rs2 = 1'b1;
                promote_rs2_mode = PY_PROMOTE_BOOL_TO_INT;
            end
        end
    endtask

    always_comb begin
        exec_unit_sel = PY_EXEC_TRAP;
        promote_rs1 = 1'b0;
        promote_rs2 = 1'b0;
        promote_rs1_mode = PY_PROMOTE_NONE;
        promote_rs2_mode = PY_PROMOTE_NONE;
        result_tag = PY_TAG_OBJECT;
        is_trap = 1'b0;
        trap_code = PY_TRAP_NONE;

        if ((alu_op == PY_ALU_ILLEGAL) || (alu_op > PY_ALU_PASS)) begin
            force_trap(PY_TRAP_ILLEGAL_OPCODE);
        end else if (pycore_is_trapping_tag(rs1_tag) &&
                     !(alu_op == PY_ALU_PASS && rs1_tag != PY_TAG_UNINIT)) begin
            force_trap(PY_TRAP_TYPE);
        end else if ((is_binary_arith(alu_op) || is_compare(alu_op) ||
                      alu_op == PY_ALU_LSHIFT || alu_op == PY_ALU_RSHIFT ||
                      alu_op == PY_ALU_AND || alu_op == PY_ALU_OR || alu_op == PY_ALU_XOR) &&
                     pycore_is_trapping_tag(rs2_tag)) begin
            force_trap(PY_TRAP_TYPE);
        end else begin
            unique case (alu_op)
                PY_ALU_PASS: begin
                    exec_unit_sel = PY_EXEC_INT;
                    result_tag = rs1_tag;
                end

                PY_ALU_NEG, PY_ALU_POS: begin
                    if (rs1_tag == PY_TAG_INT) begin
                        exec_unit_sel = PY_EXEC_INT;
                        result_tag = PY_TAG_INT;
                    end else if (rs1_tag == PY_TAG_FLOAT) begin
                        exec_unit_sel = PY_EXEC_FLOAT;
                        result_tag = PY_TAG_FLOAT;
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_INVERT: begin
                    if (rs1_tag == PY_TAG_INT) begin
                        exec_unit_sel = PY_EXEC_INT;
                        result_tag = PY_TAG_INT;
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_NOT: begin
                    if (pycore_is_numeric_tag(rs1_tag)) begin
                        exec_unit_sel = (rs1_tag == PY_TAG_FLOAT) ? PY_EXEC_FLOAT : PY_EXEC_BOOL;
                        result_tag = PY_TAG_BOOL;
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_TRUE_DIV: begin
                    if (pycore_is_numeric_tag(rs1_tag) && pycore_is_numeric_tag(rs2_tag)) begin
                        route_float_binary(PY_TAG_FLOAT);
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_ADD, PY_ALU_SUB, PY_ALU_MUL, PY_ALU_FLOOR_DIV, PY_ALU_MOD, PY_ALU_POWER: begin
                    if (rs1_tag == PY_TAG_FLOAT || rs2_tag == PY_TAG_FLOAT) begin
                        if (pycore_is_numeric_tag(rs1_tag) && pycore_is_numeric_tag(rs2_tag)) begin
                            route_float_binary(PY_TAG_FLOAT);
                        end else begin
                            force_trap(PY_TRAP_TYPE);
                        end
                    end else if (rs1_tag == PY_TAG_BOOL && rs2_tag == PY_TAG_BOOL) begin
                        route_int_binary(PY_TAG_INT);
                    end else if (pycore_is_numeric_tag(rs1_tag) && pycore_is_numeric_tag(rs2_tag)) begin
                        route_int_binary(PY_TAG_INT);
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_LSHIFT, PY_ALU_RSHIFT: begin
                    if (rs1_tag == PY_TAG_INT && rs2_tag == PY_TAG_INT) begin
                        route_int_binary(PY_TAG_INT);
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_AND, PY_ALU_OR, PY_ALU_XOR: begin
                    if (rs1_tag == PY_TAG_BOOL && rs2_tag == PY_TAG_BOOL) begin
                        exec_unit_sel = PY_EXEC_BOOL;
                        result_tag = PY_TAG_BOOL;
                    end else if ((rs1_tag == PY_TAG_INT || rs1_tag == PY_TAG_BOOL) &&
                                 (rs2_tag == PY_TAG_INT || rs2_tag == PY_TAG_BOOL)) begin
                        route_int_binary(PY_TAG_INT);
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_LE, PY_ALU_GT, PY_ALU_GE: begin
                    if (rs1_tag == PY_TAG_FLOAT || rs2_tag == PY_TAG_FLOAT) begin
                        if (pycore_is_numeric_tag(rs1_tag) && pycore_is_numeric_tag(rs2_tag)) begin
                            route_float_binary(PY_TAG_BOOL);
                        end else begin
                            force_trap(PY_TRAP_TYPE);
                        end
                    end else if ((rs1_tag == PY_TAG_BOOL || rs1_tag == PY_TAG_INT) &&
                                 (rs2_tag == PY_TAG_BOOL || rs2_tag == PY_TAG_INT)) begin
                        if (rs1_tag == PY_TAG_BOOL && rs2_tag == PY_TAG_BOOL &&
                            (alu_op == PY_ALU_EQ || alu_op == PY_ALU_NE)) begin
                            exec_unit_sel = PY_EXEC_BOOL;
                            result_tag = PY_TAG_BOOL;
                        end else begin
                            route_int_binary(PY_TAG_BOOL);
                        end
                    end else begin
                        force_trap(PY_TRAP_TYPE);
                    end
                end

                default: begin
                    force_trap(PY_TRAP_ILLEGAL_OPCODE);
                end
            endcase
        end
    end

endmodule
