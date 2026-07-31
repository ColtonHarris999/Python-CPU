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
        .string_path_valid_i(1'b0),
        .string_result_i('0),
        .string_trap_i(1'b0),
        .string_trap_code_i(PY_TRAP_NONE),
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

        rs1 = entry(PY_TAG_ITER, 64'h1000);
        rs2 = entry(PY_TAG_INT, 64'd1);
        alu_op = PY_ALU_ADD;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE, "ITER arithmetic should type trap");

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

        // Same-tag SHORT_STR equality is native (M5); empty payloads compare equal.
        rs1 = entry(PY_TAG_SHORT_STR, 64'd0);
        rs2 = entry(PY_TAG_SHORT_STR, 64'd0);
        alu_op = PY_ALU_EQ;
        #1;
        check(!trap, "same-tag SHORT_STR EQ should not trap");
        check(pycore_get_tag(result) == PY_TAG_BOOL, "string EQ should tag BOOL");
        check(result[63:0] == 64'd1, "equal SHORT_STR EQ should be true");

        alu_op = PY_ALU_NE;
        #1;
        check(!trap && result[63:0] == 64'd0,
              "equal SHORT_STR NE should be false");

        // Ordering on strings remains unsupported.
        alu_op = PY_ALU_LT;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE,
              "string ordering should type trap");

        // COMPLEX arithmetic / compare / unary
        rs1 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(1.0), $realtobits(2.0)));
        rs2 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(3.0), $realtobits(4.0)));
        alu_op = PY_ALU_ADD;
        #1;
        check(!trap, "COMPLEX add should not trap");
        check(pycore_get_tag(result) == PY_TAG_COMPLEX, "COMPLEX add should tag COMPLEX");
        check($bitstoreal(result[63:0]) == 4.0, "COMPLEX add real mismatch");
        check($bitstoreal(result[127:64]) == 6.0, "COMPLEX add imag mismatch");

        alu_op = PY_ALU_MUL;
        #1;
        check(!trap, "COMPLEX mul should not trap");
        // (1+2j)*(3+4j) = -5+10j
        check($bitstoreal(result[63:0]) == -5.0, "COMPLEX mul real mismatch");
        check($bitstoreal(result[127:64]) == 10.0, "COMPLEX mul imag mismatch");

        rs1 = pycore_make_entry(PY_TAG_INT, {{64{1'b0}}, 64'd2});
        rs2 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(1.0), $realtobits(1.0)));
        alu_op = PY_ALU_ADD;
        #1;
        check(!trap, "INT + COMPLEX should not trap");
        check(pycore_get_tag(result) == PY_TAG_COMPLEX, "INT+COMPLEX should tag COMPLEX");
        check($bitstoreal(result[63:0]) == 3.0, "INT+COMPLEX real mismatch");
        check($bitstoreal(result[127:64]) == 1.0, "INT+COMPLEX imag mismatch");

        rs1 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(1.0), $realtobits(2.0)));
        rs2 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(1.0), $realtobits(2.0)));
        alu_op = PY_ALU_EQ;
        #1;
        check(!trap && pycore_get_tag(result) == PY_TAG_BOOL,
              "COMPLEX EQ should produce BOOL");
        check(result[63:0] == 64'd1, "equal COMPLEX EQ should be true");

        alu_op = PY_ALU_LT;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE,
              "COMPLEX ordering should type trap");

        rs1 = pycore_make_entry(PY_TAG_COMPLEX,
            pycore_complex_value($realtobits(1.0), $realtobits(-2.0)));
        rs2 = entry(PY_TAG_INT, 64'd0);
        alu_op = PY_ALU_NEG;
        #1;
        check(!trap, "COMPLEX NEG should not trap");
        check($bitstoreal(result[63:0]) == -1.0, "COMPLEX NEG real mismatch");
        check($bitstoreal(result[127:64]) == 2.0, "COMPLEX NEG imag mismatch");

        $display("PASS: execute fabric smoke tests complete");
        $finish;
    end
endmodule
