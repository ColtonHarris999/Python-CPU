`include "pycore_defs.svh"

module tb_tag_decode;
    logic [3:0] rs1_tag;
    logic [3:0] rs2_tag;
    logic [4:0] alu_op;
    logic [1:0] exec_unit_sel;
    logic promote_rs1;
    logic promote_rs2;
    logic [1:0] promote_rs1_mode;
    logic [1:0] promote_rs2_mode;
    logic [3:0] result_tag;
    logic is_trap;
    logic [3:0] trap_code;

    pycore_tag_decode dut (
        .rs1_tag_i(rs1_tag),
        .rs2_tag_i(rs2_tag),
        .alu_op_i(alu_op),
        .exec_unit_sel_o(exec_unit_sel),
        .promote_rs1_o(promote_rs1),
        .promote_rs2_o(promote_rs2),
        .promote_rs1_mode_o(promote_rs1_mode),
        .promote_rs2_mode_o(promote_rs2_mode),
        .result_tag_o(result_tag),
        .is_trap_o(is_trap),
        .trap_code_o(trap_code)
    );

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    initial begin
        for (int tag_a = 0; tag_a < 16; tag_a++) begin
            for (int tag_b = 0; tag_b < 16; tag_b++) begin
                for (int op = 0; op <= PY_ALU_GE; op++) begin
                    rs1_tag = tag_a[3:0];
                    rs2_tag = tag_b[3:0];
                    alu_op = op[4:0];
                    #1;
                    check(!$isunknown(exec_unit_sel), "exec_unit_sel must be known");
                    check(!$isunknown(result_tag), "result_tag must be known");
                    check(!$isunknown(is_trap), "is_trap must be known");
                    check(!$isunknown(trap_code), "trap_code must be known");
                end
            end
        end

        rs1_tag = PY_TAG_INT;
        rs2_tag = PY_TAG_INT;
        alu_op = PY_ALU_ADD;
        #1;
        check(!is_trap, "INT + INT should not trap");
        check(exec_unit_sel == PY_EXEC_INT, "INT + INT should route to INT unit");
        check(result_tag == PY_TAG_INT, "INT + INT should produce INT");

        rs1_tag = PY_TAG_INT;
        rs2_tag = PY_TAG_FLOAT;
        alu_op = PY_ALU_TRUE_DIV;
        #1;
        check(!is_trap, "INT / FLOAT should not trap");
        check(exec_unit_sel == PY_EXEC_FLOAT, "true divide should route to FPU");
        check(result_tag == PY_TAG_FLOAT, "true divide should produce FLOAT");
        check(promote_rs1 && promote_rs1_mode == PY_PROMOTE_INT_TO_FLOAT,
              "INT operand should promote for true divide");

        rs1_tag = PY_TAG_BOOL;
        rs2_tag = PY_TAG_BOOL;
        alu_op = PY_ALU_AND;
        #1;
        check(!is_trap, "BOOL and BOOL should not trap");
        check(exec_unit_sel == PY_EXEC_BOOL, "BOOL and BOOL should route to BOOL logic");
        check(result_tag == PY_TAG_BOOL, "BOOL and BOOL should produce BOOL");

        rs1_tag = PY_TAG_SHORT_STR;
        rs2_tag = PY_TAG_LONG_STR;
        alu_op = PY_ALU_ADD;
        #1;
        check(!is_trap, "STR + STR should not trap");

        rs1_tag = PY_TAG_SHORT_STR;
        rs2_tag = PY_TAG_LONG_STR;
        alu_op = PY_ALU_MUL;
        #1;
        check(is_trap && trap_code == PY_TRAP_TYPE, "STR * STR should type trap");

        rs1_tag = PY_TAG_PTR;
        rs2_tag = PY_TAG_INT;
        alu_op = PY_ALU_EQ;
        #1;
        check(is_trap && trap_code == PY_TRAP_TYPE, "PTR compare should type trap");

        rs1_tag = PY_TAG_OBJECT;
        rs2_tag = PY_TAG_INT;
        alu_op = PY_ALU_ADD;
        #1;
        check(is_trap && trap_code == PY_TRAP_TYPE, "OBJECT arithmetic should type trap");

        $display("PASS: exhaustive tag decode smoke coverage complete");
        $finish;
    end
endmodule
