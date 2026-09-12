`include "pycore_defs.svh"

// Cache directed coverage (memory_system_plan.md §6): hit, cold miss,
// capacity/conflict miss at every way, dirty eviction, fault propagation,
// invalidate-all, flush-all, back-to-back, READ_ONLY write rejection,
// CACHE_EN=0 combinational pass-through.
module tb_cache;
    localparam int DATA_WIDTH = 128;
    localparam int ADDR_WIDTH = 32;
    localparam int LINE_BYTES = 64;
    localparam int WAYS       = 4;
    localparam int SIZE_BYTES = 256; // 1 set × 4 ways × 64 B

    logic clk, rst_n, cache_en;
    logic req, we, ack, fault;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic [ADDR_WIDTH-1:0]   addr;
    logic [DATA_WIDTH-1:0]   wdata, rdata;

    logic down_req, down_we, down_line, down_ack, down_last, down_fault;
    logic [DATA_WIDTH/8-1:0] down_wstrb;
    logic [ADDR_WIDTH-1:0]   down_addr;
    logic [DATA_WIDTH-1:0]   down_wdata, down_rdata;
    logic [LINE_BYTES*8-1:0] down_wline;

    logic inv_all, flush_all, inv_done, flush_done;
    logic [31:0] hits, misses, wbs;

    int t_first;

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SIZE_BYTES(SIZE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .READ_ONLY(1'b0),
        .WRITE_BACK(1'b1),
        .HIT_CYCLES(1)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cache_en_i(cache_en),
        .req_i(req),
        .we_i(we),
        .wstrb_i(wstrb),
        .addr_i(addr),
        .wdata_i(wdata),
        .ack_o(ack),
        .rdata_o(rdata),
        .fault_o(fault),
        .rdata_line_o(),
        .down_req_o(down_req),
        .down_we_o(down_we),
        .down_line_o(down_line),
        .down_wstrb_o(down_wstrb),
        .down_addr_o(down_addr),
        .down_wdata_o(down_wdata),
        .down_wline_o(down_wline),
        .down_ack_i(down_ack),
        .down_last_i(down_last),
        .down_rdata_i(down_rdata),
        .down_fault_i(down_fault),
        .inv_all_i(inv_all),
        .flush_all_i(flush_all),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(inv_done),
        .flush_done_o(flush_done),
        .idle_o(),
        .hit_count_o(hits),
        .miss_count_o(misses),
        .writeback_count_o(wbs),
        .region_hit_count_o(),
        .region_miss_count_o()
    );

    pycore_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .RAM_BYTES(8192),
        .T_BEAT(2),
        .DATA_LIMIT(8192),
        .DMEM_HEX(""),
        .PROG_HEX(""),
        .CODE_RAM_HEX(""),
        .DMEM_PLUSARG(""),
        .PROG_PLUSARG(""),
        .CODE_RAM_PLUSARG("")
    ) ram (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .t_first_i(t_first),
        .req_i(down_req),
        .we_i(down_we),
        .line_i(down_line),
        .wstrb_i(down_wstrb),
        .addr_i(down_addr),
        .wdata_i(down_wdata),
        .wline_i(down_wline),
        .ack_o(down_ack),
        .last_o(down_last),
        .rdata_o(down_rdata),
        .fault_o(down_fault)
    );

    logic ro_req, ro_we, ro_ack, ro_fault;
    logic [DATA_WIDTH-1:0] ro_rdata;
    logic ro_down_req;

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SIZE_BYTES(SIZE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .READ_ONLY(1'b1),
        .WRITE_BACK(1'b0),
        .HIT_CYCLES(1)
    ) dut_ro (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cache_en_i(1'b1),
        .req_i(ro_req),
        .we_i(ro_we),
        .wstrb_i({DATA_WIDTH/8{1'b1}}),
        .addr_i(32'h0),
        .wdata_i(128'h1),
        .ack_o(ro_ack),
        .rdata_o(ro_rdata),
        .fault_o(ro_fault),
        .rdata_line_o(),
        .down_req_o(ro_down_req),
        .down_we_o(),
        .down_line_o(),
        .down_wstrb_o(),
        .down_addr_o(),
        .down_wdata_o(),
        .down_wline_o(),
        .down_ack_i(1'b0),
        .down_last_i(1'b0),
        .down_rdata_i('0),
        .down_fault_i(1'b0),
        .inv_all_i(1'b0),
        .flush_all_i(1'b0),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(),
        .flush_done_o(),
        .idle_o(),
        .hit_count_o(),
        .miss_count_o(),
        .writeback_count_o(),
        .region_hit_count_o(),
        .region_miss_count_o()
    );

    // HIT_CYCLES>1 and WRITE_BACK=0 were previously untested (ST_HIT_WAIT /
    // ST_RESPOND / ST_WT_*). One instance covers all four states.
    logic cov_req, cov_we, cov_ack, cov_fault;
    logic [DATA_WIDTH-1:0] cov_rdata, cov_wdata;
    logic [ADDR_WIDTH-1:0] cov_addr;
    logic cov_down_req, cov_down_we, cov_down_line, cov_down_ack, cov_down_last, cov_down_fault;
    logic [DATA_WIDTH/8-1:0] cov_down_wstrb;
    logic [ADDR_WIDTH-1:0] cov_down_addr;
    logic [DATA_WIDTH-1:0] cov_down_wdata, cov_down_rdata;
    logic [LINE_BYTES*8-1:0] cov_down_wline;

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SIZE_BYTES(SIZE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .READ_ONLY(1'b0),
        .WRITE_BACK(1'b0),
        .HIT_CYCLES(2)
    ) dut_cov (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cache_en_i(1'b1),
        .req_i(cov_req),
        .we_i(cov_we),
        .wstrb_i({DATA_WIDTH/8{1'b1}}),
        .addr_i(cov_addr),
        .wdata_i(cov_wdata),
        .ack_o(cov_ack),
        .rdata_o(cov_rdata),
        .fault_o(cov_fault),
        .rdata_line_o(),
        .down_req_o(cov_down_req),
        .down_we_o(cov_down_we),
        .down_line_o(cov_down_line),
        .down_wstrb_o(cov_down_wstrb),
        .down_addr_o(cov_down_addr),
        .down_wdata_o(cov_down_wdata),
        .down_wline_o(cov_down_wline),
        .down_ack_i(cov_down_ack),
        .down_last_i(cov_down_last),
        .down_rdata_i(cov_down_rdata),
        .down_fault_i(cov_down_fault),
        .inv_all_i(1'b0),
        .flush_all_i(1'b0),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(),
        .flush_done_o(),
        .idle_o(),
        .hit_count_o(),
        .miss_count_o(),
        .writeback_count_o(),
        .region_hit_count_o(),
        .region_miss_count_o()
    );

    pycore_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .RAM_BYTES(8192),
        .T_BEAT(1),
        .DATA_LIMIT(8192),
        .DMEM_HEX(""),
        .PROG_HEX(""),
        .CODE_RAM_HEX(""),
        .DMEM_PLUSARG(""),
        .PROG_PLUSARG(""),
        .CODE_RAM_PLUSARG("")
    ) ram_cov (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .t_first_i(1),
        .req_i(cov_down_req),
        .we_i(cov_down_we),
        .line_i(cov_down_line),
        .wstrb_i(cov_down_wstrb),
        .addr_i(cov_down_addr),
        .wdata_i(cov_down_wdata),
        .wline_i(cov_down_wline),
        .ack_o(cov_down_ack),
        .last_o(cov_down_last),
        .rdata_o(cov_down_rdata),
        .fault_o(cov_down_fault)
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    task automatic transact(
        input bit do_we,
        input logic [ADDR_WIDTH-1:0] a,
        input logic [DATA_WIDTH-1:0] d
    );
        int n;
        @(negedge clk);
        req = 1'b1; we = do_we; addr = a; wdata = d;
        @(negedge clk);
        req = 1'b0; we = 1'b0;
        n = 0;
        while (!ack) begin
            @(negedge clk);
            n++;
            check(n < 256, "cache transact timeout");
        end
    endtask

    task automatic transact_cov(
        input bit do_we,
        input logic [ADDR_WIDTH-1:0] a,
        input logic [DATA_WIDTH-1:0] d
    );
        int n;
        @(negedge clk);
        cov_req = 1'b1; cov_we = do_we; cov_addr = a; cov_wdata = d;
        @(negedge clk);
        cov_req = 1'b0; cov_we = 1'b0;
        n = 0;
        while (!cov_ack) begin
            @(negedge clk);
            n++;
            check(n < 256, "cov cache transact timeout");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cache_en = 1'b1;
        t_first = 1;
        req = 1'b0; we = 1'b0; wstrb = '1; addr = '0; wdata = '0;
        inv_all = 1'b0; flush_all = 1'b0;
        ro_req = 1'b0; ro_we = 1'b0;
        cov_req = 1'b0; cov_we = 1'b0; cov_addr = '0; cov_wdata = '0;
        #12; rst_n = 1'b1;
        @(negedge clk);

        // Two distinct words in line 0, then conflict-evict the line.
        // Writing only word 0 used to pass even when beats 1–3 were lost.
        transact(1'b1, 32'h00, 128'hC0);
        transact(1'b1, 32'h10, 128'hC0C0);
        check(!fault, "cold write faulted");
        transact(1'b0, 32'h00, '0);
        check(rdata == 128'hC0, "hit after cold write");
        transact(1'b0, 32'h10, '0);
        check(rdata == 128'hC0C0, "second word of line 0 before eviction");
        check(misses == 32'd1, "write-allocate of line 0 is one miss");
        check(hits == 32'd3, "word1 write + two reads are hits");

        // Conflict miss at every way of the single set: lines 0,64,128,192,256.
        transact(1'b1, 32'd64,  128'hC1);
        transact(1'b1, 32'd128, 128'hC2);
        transact(1'b1, 32'd192, 128'hC3);
        transact(1'b1, 32'd256, 128'hC4); // evicts LRU (line 0), dirty WB
        check(wbs != 0, "expected a dirty writeback on 5th line");
        transact(1'b0, 32'h00, '0);
        check(rdata == 128'hC0, "evicted dirty line 0 word0 must round-trip via RAM");
        transact(1'b0, 32'h10, '0);
        check(rdata == 128'hC0C0, "evicted dirty line 0 word1 must round-trip via RAM");

        // Back-to-back hits on the refilled line.
        transact(1'b0, 32'h00, '0);
        transact(1'b0, 32'h00, '0);
        check(rdata == 128'hC0, "back-to-back hit");

        // Fault from below.
        transact(1'b0, 32'd8192, '0);
        check(fault, "OOB should propagate fault_o");

        // Invalidate-all: next access to a previously cached line misses.
        begin
            logic [31:0] misses_before;
            misses_before = misses;
            @(negedge clk);
            inv_all = 1'b1;
            @(negedge clk);
            inv_all = 1'b0;
            @(negedge clk);
            check(inv_done, "inv_done pulse");
            transact(1'b0, 32'h00, '0);
            check(misses == misses_before + 1, "invalidate-all did not miss");
            check(rdata == 128'hC0, "line 0 survived in RAM across inv");
        end

        // Dirty then flush-all: RAM must observe both words of the line.
        transact(1'b1, 32'd64, 128'hF1);
        transact(1'b1, 32'd64 + 32'h10, 128'hF2);
        @(negedge clk);
        flush_all = 1'b1;
        @(negedge clk);
        flush_all = 1'b0;
        begin
            int n;
            n = 0;
            while (!flush_done) begin
                @(negedge clk);
                n++;
                check(n < 4096, "flush timeout");
            end
        end
        // Bypass the cache so we read RAM directly.
        cache_en = 1'b0;
        transact(1'b0, 32'd64, '0);
        check(rdata == 128'hF1, "flush-all did not write dirty word0 back");
        transact(1'b0, 32'd64 + 32'h10, '0);
        check(rdata == 128'hF2, "flush-all did not write dirty word1 back");

        // CACHE_EN=0 pass-through still writes/reads.
        transact(1'b1, 32'h30, 128'hEE);
        transact(1'b0, 32'h30, '0);
        check(rdata == 128'hEE, "bypass write/read");

        // READ_ONLY write rejection.
        @(negedge clk);
        ro_req = 1'b1; ro_we = 1'b1;
        @(negedge clk);
        ro_req = 1'b0; ro_we = 1'b0;
        begin
            int n;
            n = 0;
            while (!ro_ack) begin
                @(negedge clk);
                n++;
                check(n < 8, "ro write ack timeout");
            end
        end
        check(ro_fault, "READ_ONLY write must fault");
        check(!ro_down_req, "READ_ONLY write must not issue a down request");

        // WRITE_BACK=0 write-miss (ST_WT_ISSUE/ST_WT_WAIT) then HIT_CYCLES=2
        // (ST_HIT_WAIT/ST_RESPOND). Separate instance, separate RAM.
        transact_cov(1'b1, 32'h00, 128'hAB);
        check(!cov_fault, "WT write miss faulted");
        transact_cov(1'b0, 32'h00, '0);
        check(cov_rdata == 128'hAB, "WT write did not land in RAM for the fill");
        transact_cov(1'b0, 32'h00, '0);
        check(cov_rdata == 128'hAB, "HIT_CYCLES=2 hit lost the line");
        check(!cov_fault, "HIT_CYCLES=2 hit faulted");

        $display("PASS: pycore_cache hit/miss/evict/flush/bypass isolation test");
        $finish;
    end
endmodule
