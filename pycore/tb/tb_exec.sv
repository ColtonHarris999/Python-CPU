`include "pycore_defs.svh"

module tb_exec;
    logic clk;
    logic rst_n;
    logic valid;
    logic [4:0] alu_op;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs2;
    logic [PYCORE_ENTRY_WIDTH-1:0] result;
    logic stall;
    logic trap;
    logic [4:0] trap_code;

    pycore_exec dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .valid_i(valid),
        .alu_op_i(alu_op),
        .rs1_i(rs1),
        .rs2_i(rs2),
        .result_o(result),
        .stall_o(stall),
        .trap_o(trap),
        .trap_code_o(trap_code)
    );

    always #5 clk = ~clk;

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] entry(
        input logic [3:0] tag, input logic [63:0] value
    );
        begin
            // The exec fast path only consumes value[63:0]; zero-extend the
            // 64-bit stimulus into the 128-bit value field.
            entry = pycore_make_entry(tag, {64'b0, value});
        end
    endfunction

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        alu_op = PY_ALU_ADD;
        rs1 = '0;
        rs2 = '0;
        #12;
        rst_n = 1'b1;
        valid = 1'b1;

        rs1 = entry(PY_TAG_INT, 64'd40);
        rs2 = entry(PY_TAG_INT, 64'd2);
        alu_op = PY_ALU_ADD;
        #1;
        check(!trap, "INT add should not trap");
        check(pycore_get_tag(result) == PY_TAG_INT, "INT add should tag INT");
        check(result[63:0] == 64'd42, "INT add value mismatch");
        check(result[PYCORE_VAL_MSB:64] == 64'b0, "INT add upper bits should sign-extend to zero");

        rs1 = entry(PY_TAG_BOOL, 64'd1);
        rs2 = entry(PY_TAG_BOOL, 64'd0);
        alu_op = PY_ALU_AND;
        #1;
        check(!trap, "BOOL and should not trap");
        check(pycore_get_tag(result) == PY_TAG_BOOL, "BOOL and should tag BOOL");
        check(result[63:0] == 64'd0, "BOOL and value mismatch");

        rs1 = entry(PY_TAG_INT, 64'd3);
        rs2 = entry(PY_TAG_INT, 64'd2);
        alu_op = PY_ALU_TRUE_DIV;
        #1;
        check(!trap, "INT true divide should not trap");
        check(pycore_get_tag(result) == PY_TAG_FLOAT, "INT true divide should tag FLOAT");
        check($bitstoreal(result[63:0]) == 1.5, "INT true divide value mismatch");

        rs1 = entry(PY_TAG_PTR, 64'h1000);
        rs2 = entry(PY_TAG_INT, 64'd1);
        alu_op = PY_ALU_ADD;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE, "PTR arithmetic should type trap");

        // COMPARE_OP's six selectors share this execute path.  Exercise each
        // predicate with values that distinguish its result.
        rs1 = entry(PY_TAG_INT, 64'd2);
        rs2 = entry(PY_TAG_INT, 64'd3);
        alu_op = PY_ALU_LT;
        #1;
        check(!trap, "INT less-than should not trap");
        check(pycore_get_tag(result) == PY_TAG_BOOL, "less-than should tag BOOL");
        check(result[63:0] == 64'd1, "INT less-than value mismatch");

        alu_op = PY_ALU_LE;
        #1;
        check(!trap && result[63:0] == 64'd1, "INT less-equal value mismatch");

        alu_op = PY_ALU_EQ;
        #1;
        check(!trap && result[63:0] == 64'd0, "INT equality value mismatch");

        alu_op = PY_ALU_NE;
        #1;
        check(!trap && result[63:0] == 64'd1, "INT inequality value mismatch");

        alu_op = PY_ALU_GT;
        #1;
        check(!trap && result[63:0] == 64'd0, "INT greater-than value mismatch");

        alu_op = PY_ALU_GE;
        #1;
        check(!trap && result[63:0] == 64'd0, "INT greater-equal value mismatch");
        check(result[PYCORE_VAL_MSB:64] == 64'b0,
              "comparison BOOL upper bits should be zero");

        rs1 = entry(PY_TAG_BOOL, 64'd1);
        rs2 = entry(PY_TAG_INT, 64'd0);
        alu_op = PY_ALU_GT;
        #1;
        check(!trap && pycore_get_tag(result) == PY_TAG_BOOL,
              "BOOL/INT compare should produce BOOL");
        check(result[63:0] == 64'd1, "BOOL/INT comparison value mismatch");

        rs1 = entry(PY_TAG_INT, 64'd2);
        rs2 = entry(PY_TAG_FLOAT, $realtobits(2.5));
        alu_op = PY_ALU_LT;
        #1;
        check(!trap && pycore_get_tag(result) == PY_TAG_BOOL,
              "INT/FLOAT compare should produce BOOL");
        check(result[63:0] == 64'd1, "INT/FLOAT comparison value mismatch");

        rs1 = entry(PY_TAG_SHORT_STR, 64'd0);
        rs2 = entry(PY_TAG_SHORT_STR, 64'd0);
        alu_op = PY_ALU_EQ;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE,
              "unsupported string equality should type trap");

        $display("PASS: execute fabric smoke tests complete");
        $finish;
    end
endmodule
