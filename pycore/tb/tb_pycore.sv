`include "pycore_defs.svh"

module tb_pycore;
    logic clk;
    logic rst_n;
    logic [31:0] imem_addr;
    logic [39:0] imem_rdata;
    logic trap_out;
    logic [3:0] trap_code;
    logic [63:0] cycle_count;

    logic [39:0] imem [0:3];

    pycore_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr(imem_addr),
        .imem_rdata(imem_rdata),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .cycle_count(cycle_count)
    );

    always #5 clk = ~clk;
    assign imem_rdata = imem[imem_addr[1:0]];

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        imem[0] = {32'd0, PY_OP_RESUME};
        imem[1] = {32'd0, 8'hff};
        imem[2] = 40'b0;
        imem[3] = 40'b0;
        #20;
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        if (!trap_out || trap_code != PY_TRAP_ILLEGAL_OPCODE) begin
            $error("expected illegal opcode trap, trap_out=%0d trap_code=%0d", trap_out, trap_code);
            $finish;
        end
        if (cycle_count == 64'b0) begin
            $error("cycle counter did not advance");
            $finish;
        end
        $display("PASS: pycore_top trap/counter smoke test complete");
        $finish;
    end
endmodule
