`include "pycore_defs.svh"

// Directed CODC coverage (memory_system_plan.md §6): fill, hit, way
// eviction, flush, and CACHE_EN=0 miss/pass-through.
module tb_codc;
    localparam int KEY_W     = 32;
    localparam int PAYLOAD_W = PYCORE_CODC_PAYLOAD_W;
    localparam int ENTRIES   = PYCORE_CODC_ENTRIES;
    localparam int WAYS      = PYCORE_CODC_WAYS;

    logic clk, rst_n, cache_en;
    logic lookup, fill, flush, hit;
    logic [KEY_W-1:0] lookup_key, fill_key;
    logic [PAYLOAD_W-1:0] lookup_payload, fill_payload;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] hit_count, miss_count, fill_count, flush_count;

    pycore_codc #(
        .ENTRIES(ENTRIES),
        .WAYS(WAYS)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cache_en_i(cache_en),
        .lookup_i(lookup),
        .lookup_key_i(lookup_key),
        .hit_o(hit),
        .payload_o(lookup_payload),
        .fill_i(fill),
        .fill_key_i(fill_key),
        .fill_payload_i(fill_payload),
        .flush_i(flush),
        .hit_count_o(hit_count),
        .miss_count_o(miss_count),
        .fill_count_o(fill_count),
        .flush_count_o(flush_count)
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    function automatic logic [PAYLOAD_W-1:0] mk_payload(
        input logic [63:0] entry_slot,
        input logic [127:0] consts,
        input logic [127:0] names,
        input logic [127:0] meta,
        input logic [127:0] defaults
    );
        mk_payload = {defaults, meta, names, consts, entry_slot};
    endfunction

    // Drive from negedge so the following posedge samples a stable pulse.
    task automatic do_fill(
        input logic [KEY_W-1:0] key,
        input logic [PAYLOAD_W-1:0] payload
    );
        @(negedge clk);
        fill         = 1'b1;
        fill_key     = key;
        fill_payload = payload;
        @(posedge clk);
        @(negedge clk);
        fill = 1'b0;
    endtask

    task automatic do_lookup(input logic [KEY_W-1:0] key);
        @(negedge clk);
        lookup     = 1'b1;
        lookup_key = key;
        #1;
    endtask

    task automatic lookup_done();
        @(posedge clk);
        @(negedge clk);
        lookup = 1'b0;
    endtask

    task automatic do_flush();
        @(negedge clk);
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
    endtask

    // Same-set addresses: (addr >> 6) & 1 == 0.
    localparam logic [31:0] A0 = 32'h0000_0000;
    localparam logic [31:0] A1 = 32'h0000_0080;
    localparam logic [31:0] A2 = 32'h0000_0100;
    // Other set: (addr >> 6) & 1 == 1.
    localparam logic [31:0] B0 = 32'h0000_0040;

    logic [PAYLOAD_W-1:0] p0, p1, p2, pb;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cache_en = 1'b1;
        lookup = 1'b0;
        fill = 1'b0;
        flush = 1'b0;
        lookup_key = '0;
        fill_key = '0;
        fill_payload = '0;
        p0 = mk_payload(64'h11, 128'hC0, 128'hA0, 128'hB0, 128'hD0);
        p1 = mk_payload(64'h22, 128'hC1, 128'hA1, 128'hB1, 128'hD1);
        p2 = mk_payload(64'h33, 128'hC2, 128'hA2, 128'hB2, 128'hD2);
        pb = mk_payload(64'h44, 128'hCB, 128'hAB, 128'hBB, 128'hDB);

        #12;
        rst_n = 1'b1;
        @(negedge clk);

        // Cold miss.
        do_lookup(A0);
        check(!hit, "cold lookup must miss");
        lookup_done();

        // Fill A0, then hit.
        do_fill(A0, p0);
        do_lookup(A0);
        check(hit, "A0 should hit after fill");
        check(lookup_payload == p0, "A0 payload mismatch");
        lookup_done();

        // Second way of the same set, plus the other set.
        do_fill(A1, p1);
        do_fill(B0, pb);
        do_lookup(A0);
        check(hit && (lookup_payload == p0), "A0 still present");
        lookup_done();
        do_lookup(A1);
        check(hit && (lookup_payload == p1), "A1 hit");
        lookup_done();
        do_lookup(B0);
        check(hit && (lookup_payload == pb), "B0 other-set hit");
        lookup_done();

        // A1 was just touched so A0 is LRU. Filling A2 evicts A0.
        do_lookup(A1);
        check(hit, "touch A1 before eviction");
        lookup_done();
        do_fill(A2, p2);
        do_lookup(A2);
        check(hit && (lookup_payload == p2), "A2 occupies the evicted way");
        lookup_done();
        do_lookup(A0);
        check(!hit, "A0 must be evicted (LRU)");
        lookup_done();
        do_lookup(A1);
        check(hit && (lookup_payload == p1), "A1 (MRU) survives eviction");
        lookup_done();
        do_lookup(B0);
        check(hit && (lookup_payload == pb), "other set is untouched");
        lookup_done();

        // Flush drops every way.
        do_flush();
        do_lookup(A1);
        check(!hit, "flush must drop A1");
        lookup_done();
        do_lookup(A2);
        check(!hit, "flush must drop A2");
        lookup_done();
        do_lookup(B0);
        check(!hit, "flush must drop B0");
        lookup_done();

        // Refill after flush, then CACHE_EN=0 ignores the live entry.
        do_fill(A0, p0);
        do_lookup(A0);
        check(hit, "refill after flush hits");
        lookup_done();
        cache_en = 1'b0;
        do_lookup(A0);
        check(!hit, "CACHE_EN=0 is always a miss");
        lookup_done();
        do_fill(A1, p1);
        cache_en = 1'b1;
        do_lookup(A1);
        check(!hit, "fill while CACHE_EN=0 must not install");
        lookup_done();
        do_lookup(A0);
        check(hit && (lookup_payload == p0), "pre-disable entry still present");
        lookup_done();

        check(fill_count >= 4, "expected several fills");
        check(flush_count >= 1, "expected a flush");
        check(hit_count >= 1, "expected hits");
        check(miss_count >= 1, "expected misses");

        $display("PASS: CODC fill/hit/evict/flush (hits=%0d misses=%0d fills=%0d flushes=%0d)",
                 hit_count, miss_count, fill_count, flush_count);
        $finish;
    end
endmodule
