`timescale 1ns/1ps
import pycore_types_pkg::*;

module tb_alu;
    logic clk;
    logic rst_n;
    logic start;
    logic [5:0] cmd;
    logic [65:0] op_a;
    logic [65:0] op_b;
    logic [65:0] result;
    logic done;
    logic stall;
    logic trap;
    logic [3:0] trap_code;

    pycore_alu #(
        .DIV_LATENCY(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .cmd(cmd),
        .op_a(op_a),
        .op_b(op_b),
        .result(result),
        .done(done),
        .stall(stall),
        .trap(trap),
        .trap_code(trap_code)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        cmd = ALU_NOP;
        op_a = {TAG_UNINIT, 64'd0};
        op_b = {TAG_UNINIT, 64'd0};
        #20;
        rst_n = 1'b1;

        // INT add path.
        start = 1'b1;
        cmd = ALU_ADD;
        op_a = {TAG_INT, 64'sd7};
        op_b = {TAG_INT, 64'sd5};
        #10;
        if (trap || result[65:64] != TAG_INT || $signed(result[63:0]) != 12) begin
            $fatal(1, "ALU add failed");
        end

        // BOOL->INT promotion path.
        cmd = ALU_ADD;
        op_a = {TAG_BOOL, 64'd1};
        op_b = {TAG_INT, 64'd9};
        #10;
        if (trap || result[65:64] != TAG_INT || $signed(result[63:0]) != 10) begin
            $fatal(1, "ALU bool promotion failed");
        end

        // BOOL logical and.
        cmd = ALU_AND;
        op_a = {TAG_BOOL, 64'd1};
        op_b = {TAG_BOOL, 64'd0};
        #10;
        if (trap || result[65:64] != TAG_BOOL || result[0] != 1'b0) begin
            $fatal(1, "ALU bool logical and failed");
        end

        $display("PASS: tb_alu");
        $finish;
    end
endmodule
