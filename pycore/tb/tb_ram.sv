`include "pycore_defs.svh"

// RAM model: T_FIRST honoured, line-burst ordering, write then read-back
// (memory_system_plan.md §6).
module tb_ram;
    localparam int DATA_WIDTH = 128;
    localparam int ADDR_WIDTH = 32;
    localparam int LINE_BYTES = 64;
    localparam int RAM_BYTES  = 4096;

    logic clk, rst_n;
    int   t_first;
    logic req, we, line, ack, last, fault;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic [ADDR_WIDTH-1:0]   addr;
    logic [DATA_WIDTH-1:0]   wdata, rdata;
    logic [LINE_BYTES*8-1:0] wline;

    pycore_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .RAM_BYTES(RAM_BYTES),
        .T_BEAT(2),
        .DATA_LIMIT(RAM_BYTES),
        .DMEM_HEX(""),
        .PROG_HEX(""),
        .CODE_RAM_HEX(""),
        .DMEM_PLUSARG(""),
        .PROG_PLUSARG(""),
        .CODE_RAM_PLUSARG("")
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .t_first_i(t_first),
        .req_i(req),
        .we_i(we),
        .line_i(line),
        .wstrb_i(wstrb),
        .addr_i(addr),
        .wdata_i(wdata),
        .wline_i(wline),
        .ack_o(ack),
        .last_o(last),
        .rdata_o(rdata),
        .fault_o(fault)
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    task automatic wait_ack(output int cycles);
        cycles = 1;
        while (!ack) begin
            @(negedge clk);
            cycles++;
            check(cycles < 64, "timeout waiting for ram ack");
        end
    endtask

    int lat;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        t_first = 1;
        req = 1'b0;
        we = 1'b0;
        line = 1'b0;
        wstrb = '1;
        addr = '0;
        wdata = '0;
        wline = '0;
        #12;
        rst_n = 1'b1;
        @(negedge clk);

        // T_FIRST=1 word write/read.
        t_first = 1;
        @(negedge clk);
        req = 1'b1; we = 1'b1; line = 1'b0; addr = 32'h10;
        wdata = 128'hA1A2A3A4A5A6A7A8A9AAABACADAEAFB0;
        @(negedge clk);
        req = 1'b0; we = 1'b0;
        wait_ack(lat);
        check(lat == 1, $sformatf("T_FIRST=1 write ack in %0d", lat));
        check(!fault, "in-range write faulted");

        @(negedge clk);
        req = 1'b1; we = 1'b0; addr = 32'h10; wdata = '0;
        @(negedge clk);
        req = 1'b0;
        wait_ack(lat);
        check(rdata == 128'hA1A2A3A4A5A6A7A8A9AAABACADAEAFB0, "T_FIRST=1 readback");

        // T_FIRST=4.
        t_first = 4;
        @(negedge clk);
        req = 1'b1; we = 1'b1; addr = 32'h20;
        wdata = 128'h11111111111111112222222222222222;
        @(negedge clk);
        req = 1'b0; we = 1'b0;
        wait_ack(lat);
        check(lat == 4, $sformatf("T_FIRST=4 write ack in %0d", lat));
        @(negedge clk);
        req = 1'b1; we = 1'b0; addr = 32'h20;
        @(negedge clk);
        req = 1'b0;
        wait_ack(lat);
        check(lat == 4, $sformatf("T_FIRST=4 read ack in %0d", lat));
        check(rdata == 128'h11111111111111112222222222222222, "T_FIRST=4 readback");

        // T_FIRST=30.
        t_first = 30;
        @(negedge clk);
        req = 1'b1; we = 1'b0; addr = 32'h10;
        @(negedge clk);
        req = 1'b0;
        wait_ack(lat);
        check(lat == 30, $sformatf("T_FIRST=30 read ack in %0d", lat));
        check(rdata == 128'hA1A2A3A4A5A6A7A8A9AAABACADAEAFB0, "T_FIRST=30 preserved");

        // Line burst write then read-back. T_FIRST=1, T_BEAT=2.
        // Capture the whole line on req, then poison live wdata/wline so a
        // producer that lags its beat on ack cannot "help" later beats.
        t_first = 1;
        begin
            logic [127:0] beats [0:3];
            logic [LINE_BYTES*8-1:0] packed_line;
            int b;
            beats[0] = 128'hA0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0;
            beats[1] = 128'h01010101010101010101010101010101;
            beats[2] = 128'h02020202020202020202020202020202;
            beats[3] = 128'h03030303030303030303030303030303;
            packed_line = {beats[3], beats[2], beats[1], beats[0]};
            @(negedge clk);
            req = 1'b1; we = 1'b1; line = 1'b1; addr = 32'h80;
            wdata = beats[0];
            wline = packed_line;
            @(negedge clk);
            req = 1'b0;
            wdata = '1;
            wline = '1;
            for (b = 0; b < 4; b++) begin
                wait_ack(lat);
                if (b == 0)
                    check(lat == 1, $sformatf("burst first beat lat %0d", lat));
                else
                    check(lat == 2, $sformatf("burst beat %0d lat %0d", b, lat));
                check(last == (b == 3), $sformatf("last_o mismatch beat %0d", b));
                if (b != 3) begin
                    while (ack) @(negedge clk);
                end
            end
            line = 1'b0; we = 1'b0;
            wdata = '0;
            wline = '0;

            @(negedge clk);
            req = 1'b1; we = 1'b0; line = 1'b1; addr = 32'h80; wdata = '0;
            @(negedge clk);
            req = 1'b0;
            for (b = 0; b < 4; b++) begin
                wait_ack(lat);
                check(rdata == beats[b], $sformatf("burst read beat %0d", b));
                check(last == (b == 3), $sformatf("read last_o beat %0d", b));
                if (b != 3) begin
                    while (ack) @(negedge clk);
                end
            end
            line = 1'b0;
        end

        // OOB fault.
        @(negedge clk);
        req = 1'b1; we = 1'b0; line = 1'b0; addr = 32'(RAM_BYTES);
        @(negedge clk);
        req = 1'b0;
        wait_ack(lat);
        check(fault, "OOB should fault");

        $display("PASS: pycore_ram latency/burst/writeback isolation test");
        $finish;
    end
endmodule
