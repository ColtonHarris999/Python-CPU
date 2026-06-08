`include "pycore_defs.svh"

module tb_exec;
    logic clk;
    logic rst_n;
    logic valid;
    logic [4:0] alu_op;
    logic [66:0] rs1;
    logic [66:0] rs2;
    logic [66:0] result;
    logic stall;
    logic trap;
    logic [3:0] trap_code;

    pycore_exec dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid(valid),
        .alu_op(alu_op),
        .rs1(rs1),
        .rs2(rs2),
        .result(result),
        .stall(stall),
        .trap(trap),
        .trap_code(trap_code)
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

    function automatic logic [66:0] entry(input logic [2:0] tag, input logic [63:0] value);
        begin
            entry = {tag, value};
        end
    endfunction

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        alu_op = PY_ALU_ADD;
        rs1 = 67'b0;
        rs2 = 67'b0;
        #12;
        rst_n = 1'b1;
        valid = 1'b1;

        rs1 = entry(PY_TAG_INT, 64'd40);
        rs2 = entry(PY_TAG_INT, 64'd2);
        alu_op = PY_ALU_ADD;
        #1;
        check(!trap, "INT add should not trap");
        check(result[66:64] == PY_TAG_INT, "INT add should tag INT");
        check(result[63:0] == 64'd42, "INT add value mismatch");

        rs1 = entry(PY_TAG_BOOL, 64'd1);
        rs2 = entry(PY_TAG_BOOL, 64'd0);
        alu_op = PY_ALU_AND;
        #1;
        check(!trap, "BOOL and should not trap");
        check(result[66:64] == PY_TAG_BOOL, "BOOL and should tag BOOL");
        check(result[63:0] == 64'd0, "BOOL and value mismatch");

        rs1 = entry(PY_TAG_INT, 64'd3);
        rs2 = entry(PY_TAG_INT, 64'd2);
        alu_op = PY_ALU_TRUE_DIV;
        #1;
        check(!trap, "INT true divide should not trap");
        check(result[66:64] == PY_TAG_FLOAT, "INT true divide should tag FLOAT");
        check($bitstoreal(result[63:0]) == 1.5, "INT true divide value mismatch");

        rs1 = entry(PY_TAG_PTR, 64'h1000);
        rs2 = entry(PY_TAG_INT, 64'd1);
        alu_op = PY_ALU_ADD;
        #1;
        check(trap && trap_code == PY_TRAP_TYPE, "PTR arithmetic should type trap");

        $display("PASS: execute fabric smoke tests complete");
        $finish;
    end
endmodule
