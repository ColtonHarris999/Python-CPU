`include "pycore_defs.svh"

// P3 directed test (memory_system_plan.md): dirty a line in L1D, flush,
// then read the same address through the excore L2 port and check the
// written-back data. Also covers CACHE_EN=0 (flush_done still pulses)
// and the stale-without-flush case that makes the handoff necessary.
module tb_l1d_handoff;
    localparam int DATA_WIDTH = PYCORE_DMEM_DATA_WIDTH;
    localparam int ADDR_WIDTH = PYCORE_ADDR_WIDTH;
    localparam logic [ADDR_WIDTH-1:0] ADDR = 32'h0000_1000;
    localparam logic [ADDR_WIDTH-1:0] ADDR1 = ADDR + 32'h10;
    localparam logic [DATA_WIDTH-1:0] PATTERN = 128'hA1B2_C3D4_E5F6_7788_99AA_BBCC_DDEE_FF01;
    localparam logic [DATA_WIDTH-1:0] PATTERN1 = 128'hC0C0_C0C0_C0C0_C0C0_C0C0_C0C0_C0C0_C0C0;

    logic clk, rst_n, cache_en;
    int   t_first;

    logic                   dmem_req, dmem_we, dmem_ack, dmem_fault;
    logic [DATA_WIDTH/8-1:0] dmem_wstrb;
    logic [ADDR_WIDTH-1:0]  dmem_addr;
    logic [DATA_WIDTH-1:0]  dmem_wdata, dmem_rdata;

    logic                   ex_req, ex_we, ex_ack, ex_fault;
    logic [DATA_WIDTH/8-1:0] ex_wstrb;
    logic [ADDR_WIDTH-1:0]  ex_addr;
    logic [DATA_WIDTH-1:0]  ex_wdata, ex_rdata;

    logic flush_req, inv_req, flush_done, inv_done;

    pycore_mem_hier #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DMEM_DATA_W(DATA_WIDTH),
        .PROG_HEX(""),
        .CODE_RAM_HEX(""),
        .DMEM_HEX("")
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cache_en_i(cache_en),
        .t_first_i(t_first),
        .imem_req_i(1'b0),
        .imem_we_i(1'b0),
        .imem_wstrb_i('0),
        .imem_addr_i('0),
        .imem_wdata_i('0),
        .imem_ack_o(),
        .imem_rdata_o(),
        .imem_fault_o(),
        .imem_line_o(),
        .imem_line_valid_o(),
        .dmem_req_i(dmem_req),
        .dmem_we_i(dmem_we),
        .dmem_line_i(1'b0),
        .dmem_wstrb_i(dmem_wstrb),
        .dmem_addr_i(dmem_addr),
        .dmem_wdata_i(dmem_wdata),
        .dmem_wline_i('0),
        .dmem_ack_o(dmem_ack),
        .dmem_rdata_o(dmem_rdata),
        .dmem_fault_o(dmem_fault),
        .excore_req_i(ex_req),
        .excore_we_i(ex_we),
        .excore_wstrb_i(ex_wstrb),
        .excore_addr_i(ex_addr),
        .excore_wdata_i(ex_wdata),
        .excore_ack_o(ex_ack),
        .excore_rdata_o(ex_rdata),
        .excore_fault_o(ex_fault),
        .flush_req_i(flush_req),
        .inv_req_i(inv_req),
        .flush_done_o(flush_done),
        .inv_done_o(inv_done),
        .l1d_idle_o(),
        .l1i_hit_count_o(),
        .l1i_miss_count_o(),
        .l1d_hit_count_o(),
        .l1d_miss_count_o(),
        .l1d_writeback_count_o(),
        .l1d_frame_hit_count_o(),
        .l1d_frame_miss_count_o(),
        .l2_hit_count_o(),
        .l2_miss_count_o(),
        .l2_writeback_count_o()
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    task automatic dmem_xact(
        input bit we,
        input logic [ADDR_WIDTH-1:0] a,
        input logic [DATA_WIDTH-1:0] d
    );
        int n;
        @(negedge clk);
        dmem_req = 1'b1; dmem_we = we; dmem_addr = a; dmem_wdata = d;
        @(negedge clk);
        dmem_req = 1'b0; dmem_we = 1'b0;
        n = 0;
        while (!dmem_ack) begin
            @(negedge clk);
            n++;
            check(n < 4096, "dmem transact timeout");
        end
        check(!dmem_fault, "dmem fault");
    endtask

    task automatic ex_xact(
        input bit we,
        input logic [ADDR_WIDTH-1:0] a,
        input logic [DATA_WIDTH-1:0] d
    );
        int n;
        @(negedge clk);
        ex_req = 1'b1; ex_we = we; ex_addr = a; ex_wdata = d;
        @(negedge clk);
        ex_req = 1'b0; ex_we = 1'b0;
        n = 0;
        while (!ex_ack) begin
            @(negedge clk);
            n++;
            check(n < 4096, "excore transact timeout");
        end
        check(!ex_fault, "excore fault");
    endtask

    task automatic do_flush();
        int n;
        @(negedge clk);
        flush_req = 1'b1;
        @(negedge clk);
        flush_req = 1'b0;
        n = 0;
        while (!flush_done) begin
            @(negedge clk);
            n++;
            check(n < 16384, "flush timeout");
        end
    endtask

    task automatic do_inv();
        int n;
        @(negedge clk);
        inv_req = 1'b1;
        @(negedge clk);
        inv_req = 1'b0;
        n = 0;
        while (!inv_done) begin
            @(negedge clk);
            n++;
            check(n < 4096, "inv timeout");
        end
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        dmem_req = 1'b0; dmem_we = 1'b0; dmem_wstrb = '1;
        dmem_addr = '0; dmem_wdata = '0;
        ex_req = 1'b0; ex_we = 1'b0; ex_wstrb = '1;
        ex_addr = '0; ex_wdata = '0;
        flush_req = 1'b0; inv_req = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    initial begin
        clk = 1'b0;
        t_first = 1;

        // --- CACHE_EN=1: dirty L1D, excore must not see the store until flush
        cache_en = 1'b1;
        reset_dut();
        dmem_xact(1'b1, ADDR, PATTERN);
        dmem_xact(1'b1, ADDR1, PATTERN1);
        dmem_xact(1'b0, ADDR, '0);
        check(dmem_rdata == PATTERN, "L1D hit did not return the stored pattern");
        dmem_xact(1'b0, ADDR1, '0);
        check(dmem_rdata == PATTERN1, "L1D hit lost the second word of the line");

        ex_xact(1'b0, ADDR, '0);
        check(ex_rdata != PATTERN,
              "excore saw L1D-dirty data before flush (handoff would be racy)");

        do_flush();
        ex_xact(1'b0, ADDR, '0);
        check(ex_rdata == PATTERN, "excore did not observe L1D writeback after flush");
        ex_xact(1'b0, ADDR1, '0);
        check(ex_rdata == PATTERN1, "excore lost the second flushed word");

        // Invalidate drops the L1D copy; a subsequent dmem read refills from L2.
        do_inv();
        dmem_xact(1'b0, ADDR, '0);
        check(dmem_rdata == PATTERN, "dmem refill after inv lost the flushed line");
        dmem_xact(1'b0, ADDR1, '0);
        check(dmem_rdata == PATTERN1, "dmem refill after inv lost word1");

        // --- CACHE_EN=0: pass-through still completes flush_done, data visible
        cache_en = 1'b0;
        reset_dut();
        dmem_xact(1'b1, ADDR + 32'h40, PATTERN ^ 128'h1);
        do_flush();
        ex_xact(1'b0, ADDR + 32'h40, '0);
        check(ex_rdata == (PATTERN ^ 128'h1), "CACHE_EN=0 excore read mismatch");

        $display("PASS: L1D handoff flush/inv (CACHE_EN=0 and 1)");
        $finish;
    end
endmodule
