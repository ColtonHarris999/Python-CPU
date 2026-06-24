`include "pycore_defs.svh"

// Phase B isolation test: proves the tiled bank does real read/write, returns
// data with one-cycle ack latency, decodes across multiple blocks, and faults on
// an out-of-range address.
module tb_mem_bank;
    localparam int DATA_WIDTH  = 128;
    localparam int ADDR_WIDTH  = 32;
    localparam int BLOCK_SHIFT = 6;   // 64 bytes / block
    localparam int BLOCK_COUNT = 2;   // 128 bytes total, addr 128+ faults

    logic clk;
    logic rst_n;
    logic req;
    logic we;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] wdata;
    logic ack;
    logic [DATA_WIDTH-1:0] rdata;
    logic fault;

    pycore_mem_bank #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(BLOCK_COUNT),
        .READ_ONLY(0),
        .INIT_HEX("")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req(req),
        .we(we),
        .addr(addr),
        .wdata(wdata),
        .ack(ack),
        .rdata(rdata),
        .fault(fault)
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

    // Drive a single-cycle request and sample the response on the next negedge,
    // i.e. exactly one ack-latency cycle later.
    task automatic transact(
        input bit                  do_we,
        input logic [ADDR_WIDTH-1:0] a,
        input logic [DATA_WIDTH-1:0] d
    );
        begin
            @(negedge clk);
            req   = 1'b1;
            we    = do_we;
            addr  = a;
            wdata = d;
            @(negedge clk);
            req = 1'b0;
            we  = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        req = 1'b0;
        we = 1'b0;
        addr = '0;
        wdata = '0;
        #12;
        rst_n = 1'b1;

        // Write/read block 0, word 1 (byte addr 16).
        transact(1'b1, 32'd16, 128'hdead_beef_0000_0000_0000_0000_cafe_f00d);
        check(ack, "write ack should assert after one cycle");
        check(!fault, "in-range write should not fault");

        transact(1'b0, 32'd16, '0);
        check(ack, "read ack should assert after one cycle");
        check(!fault, "in-range read should not fault");
        check(rdata == 128'hdead_beef_0000_0000_0000_0000_cafe_f00d,
              "block0 readback mismatch");

        // Write/read block 1, word 2 (byte addr 64 + 32 = 96).
        transact(1'b1, 32'd96, 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210);
        transact(1'b0, 32'd96, '0);
        check(rdata == 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210,
              "block1 readback mismatch");

        // Confirm block 0 word 1 still holds its value (no cross-block clobber).
        transact(1'b0, 32'd16, '0);
        check(rdata == 128'hdead_beef_0000_0000_0000_0000_cafe_f00d,
              "block0 value clobbered by block1 write");

        // Out-of-range address: block_idx = 2 >= BLOCK_COUNT.
        transact(1'b0, 32'd128, '0);
        check(ack, "out-of-range access should still ack");
        check(fault, "out-of-range access should fault");

        $display("PASS: pycore_mem_bank read/write/ack/fault isolation test complete");
        $finish;
    end
endmodule
