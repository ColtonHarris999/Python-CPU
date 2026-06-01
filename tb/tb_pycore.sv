`timescale 1ns/1ps

module tb_pycore;
    logic clk;
    logic rst_n;
    logic trap_out;
    logic [3:0] trap_code;
    logic [63:0] cycle_count;
    logic halted;
    logic ret_valid;
    logic [1:0] ret_tag;
    logic [63:0] ret_value;

    pycore_top #(
        .PROG_HEX("programs/pycore_prog.hex"),
        .CONST_HEX("programs/pycore_consts.hex")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .cycle_count(cycle_count),
        .halted(halted),
        .ret_valid(ret_valid),
        .ret_tag(ret_tag),
        .ret_value(ret_value)
    );

    always #5 clk = ~clk;

    initial begin
        int cycles;
        clk = 1'b0;
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;

        for (cycles = 0; cycles < 2000; cycles++) begin
            #10;
            if (trap_out) begin
                $display("TRAP: code=%0d cycle=%0d", trap_code, cycles);
                $finish;
            end
            if (halted) begin
                $display("HALT: ret_valid=%0d tag=%0d value=%0d cycles=%0d", ret_valid, ret_tag, ret_value, cycle_count);
                $finish;
            end
        end

        $fatal(1, "timeout waiting for halt/trap");
    end
endmodule
