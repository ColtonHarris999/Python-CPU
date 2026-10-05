`include "pycore_defs.svh"

// Non-blocking L1D port and pipelined L2 (pycore_cache NB / PIPE) through
// the real hierarchy: L1D -> xbar -> L2 -> RAM. One ordinary master (one
// request at a time, held until its ack, like the core) and one
// non-blocking master (tagged reads and prefetches, several in flight) run
// together on random addresses that conflict in both L1D and L2. Every
// response is checked against a shadow memory:
//   - an ordinary read returns the shadow word (only the ordinary master
//     writes, one request at a time);
//   - a non-blocking read returns the shadow line as it was when the read
//     was accepted (an ordinary write to that line cannot overtake it: it
//     misses and waits for the port to drain, or it is held off by nb_gnt);
//   - at the end every touched line is read back with ordinary reads.
// Ordinary requests are held until their ack or pulsed for one cycle (the
// cache must capture them either way). Also checks that every tagged read
// answers exactly once and that the port drains (l1d_idle_o). +SEED=, +MEM_LATENCY=, +CYCLES=.
module tb_mem_nb;
    localparam int DW = PYCORE_DMEM_DATA_WIDTH;
    localparam int AW = PYCORE_ADDR_WIDTH;
    localparam int LW = PYCORE_LINE_BYTES * 8;

    logic clk = 1'b0, rst_n = 1'b0;
    int   t_first;
    always #5 clk = ~clk;

    logic          d_req = 1'b0, d_we = 1'b0, d_line = 1'b0, d_ack, d_fault;
    logic [DW/8-1:0] d_wstrb = '0;
    logic [AW-1:0] d_addr = '0;
    logic [DW-1:0] d_wdata = '0, d_rdata;
    logic [LW-1:0] d_wline = '0;
    logic          nb_req = 1'b0, nb_pf = 1'b0, nb_gnt, nb_ack, nb_fault;
    logic [AW-1:0] nb_addr = '0;
    logic [3:0]    nb_id = '0, nb_rid;
    logic [LW-1:0] nb_line;
    logic          l1d_idle;
    logic [31:0]   l1d_hits, l1d_misses, l1d_wbs, l2_hits, l2_misses, l2_wbs;

    /* verilator lint_off PINCONNECTEMPTY */
    pycore_mem_hier #(
        .PROG_HEX(""), .CODE_RAM_HEX(""), .DMEM_HEX("")
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .cache_en_i(1'b1), .t_first_i(t_first),
        .imem_req_i(1'b0), .imem_we_i(1'b0), .imem_wstrb_i('0), .imem_addr_i('0),
        .imem_wdata_i('0), .imem_ack_o(), .imem_rdata_o(), .imem_fault_o(),
        .imem_line_o(), .imem_line_valid_o(),
        .dmem_req_i(d_req), .dmem_we_i(d_we), .dmem_line_i(d_line), .dmem_wstrb_i(d_wstrb),
        .dmem_addr_i(d_addr), .dmem_wdata_i(d_wdata), .dmem_wline_i(d_wline),
        .dmem_ack_o(d_ack), .dmem_rdata_o(d_rdata), .dmem_fault_o(d_fault),
        .dmem_rdata_line_o(),
        .dmem_nb_req_i(nb_req), .dmem_nb_pf_i(nb_pf), .dmem_nb_addr_i(nb_addr),
        .dmem_nb_id_i(nb_id), .dmem_nb_gnt_o(nb_gnt), .dmem_nb_ack_o(nb_ack),
        .dmem_nb_fault_o(nb_fault), .dmem_nb_id_o(nb_rid), .dmem_nb_line_o(nb_line),
        .excore_req_i(1'b0), .excore_we_i(1'b0), .excore_wstrb_i('0), .excore_addr_i('0),
        .excore_wdata_i('0), .excore_ack_o(), .excore_rdata_o(), .excore_fault_o(),
        .flush_req_i(1'b0), .inv_req_i(1'b0), .flush_done_o(), .inv_done_o(),
        .l1d_idle_o(l1d_idle),
        .l1i_hit_count_o(), .l1i_miss_count_o(), .l1d_hit_count_o(l1d_hits),
        .l1d_miss_count_o(l1d_misses), .l1d_writeback_count_o(l1d_wbs),
        .l1d_frame_hit_count_o(), .l1d_frame_miss_count_o(),
        .l2_hit_count_o(l2_hits), .l2_miss_count_o(l2_misses), .l2_writeback_count_o(l2_wbs)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Shadow memory, one 16 B word per entry (absent: zero).
    logic [DW-1:0] shadow [int unsigned];
    function automatic logic [DW-1:0] sh_word(input logic [AW-1:0] a);
        int unsigned k = a >> 4;
        return shadow.exists(k) ? shadow[k] : '0;
    endfunction
    function automatic logic [LW-1:0] sh_line(input logic [AW-1:0] a);
        logic [LW-1:0] l;
        for (int b = 0; b < LW / DW; b++)
            l[b*DW +: DW] = sh_word({a[AW-1:6], 6'd0} + AW'(b * 16));
        return l;
    endfunction

    // Lines from a 1.5 MB window: 64 L1D/L2 sets x 24 tags 64 KB apart, so
    // both caches evict (L1D 4-way, L2 8-way) and L2 writes back to RAM.
    function automatic logic [AW-1:0] rand_line();
        return AW'(32'h0010_0000) + AW'(($urandom % 64) * 64) +
               AW'(($urandom % 24) * 32'h1_0000);
    endfunction

    int errors = 0;
    task automatic fail(input string msg);
        $display("FAIL: %s", msg);
        errors++;
        if (errors > 10) $finish;
    endtask

    // Outstanding tagged reads.
    bit            nb_out [0:15];
    logic [LW-1:0] nb_exp [0:15];
    logic [AW-1:0] nb_exp_addr [0:15];
    bit            touched [int unsigned];

    int n_leg_rd = 0, n_leg_wr = 0, n_nb_rd = 0, n_nb_pf = 0, n_nb_ack = 0;
    int n_overlap = 0;

    initial begin
        int seed, cycles, leg_wait;
        bit leg_busy, leg_is_rd, leg_pulse;
        logic [DW-1:0] leg_exp;
        logic [AW-1:0] leg_a;
        seed = 1;
        void'($value$plusargs("SEED=%d", seed));
        void'($urandom(seed));
        t_first = PYCORE_RAM_T_FIRST_CI;
        void'($value$plusargs("MEM_LATENCY=%d", t_first));
        cycles = 200000;
        void'($value$plusargs("CYCLES=%d", cycles));
        for (int i = 0; i < 16; i++) nb_out[i] = 1'b0;
        leg_busy = 1'b0; leg_is_rd = 1'b0; leg_pulse = 1'b0; leg_exp = '0; leg_a = '0; leg_wait = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (int c = 0; c < cycles + 20000; c++) begin
            bit draining, granted;
            draining = (c >= cycles);
            granted  = 1'b0;
            // ---- sample responses of the cycle that just ended ----
            if (nb_ack) begin
                n_nb_ack++;
                if (!nb_out[nb_rid]) fail($sformatf("nb ack for idle id %0d", nb_rid));
                else if (nb_fault) fail($sformatf("nb fault id %0d", nb_rid));
                else if (nb_line !== nb_exp[nb_rid])
                    fail($sformatf("nb id %0d line %h: got %h want %h", nb_rid,
                                   nb_exp_addr[nb_rid], nb_line, nb_exp[nb_rid]));
                nb_out[nb_rid] = 1'b0;
            end
            if (leg_busy && d_ack) begin
                if (d_fault) fail($sformatf("ordinary fault at %h", leg_a));
                else if (leg_is_rd && d_rdata !== leg_exp)
                    fail($sformatf("ordinary read %h: got %h want %h", leg_a, d_rdata, leg_exp));
                leg_busy = 1'b0;
                d_req = 1'b0; d_we = 1'b0; d_line = 1'b0;
            end
            if (leg_busy) begin
                leg_wait++;
                if (leg_wait > 20000) fail("ordinary request never answered");
            end
            if (leg_busy) begin
                int k;
                k = 0;
                for (int i = 0; i < 16; i++) k += nb_out[i];
                if (k != 0) n_overlap++;
            end

            // ---- non-blocking master: one request held until granted ----
            if (nb_req) begin
                // Sampled before the edge below: accepted there if granted.
            end else if (!draining && ($urandom % 3) == 0) begin
                int id;
                id = -1;
                for (int i = 0; i < 16; i++) if (!nb_out[i] && id < 0) id = i;
                nb_addr = rand_line() + AW'(($urandom % 4) * 16);
                nb_pf   = (id < 0) || (($urandom % 2) == 0);
                nb_id   = (id < 0) ? 4'd0 : 4'(id);
                nb_req  = 1'b1;
            end

            // ---- ordinary master ----
            if (!leg_busy && !draining && ($urandom % 4) == 0) begin
                int r;
                r = $urandom % 10;
                leg_a = rand_line() + AW'(($urandom % 4) * 16);
                touched[leg_a >> 6] = 1'b1;
                d_req = 1'b1; leg_busy = 1'b1; leg_wait = 0;
                // Half the requests are one-cycle pulses (the GC engine and
                // STRACC), half are held until the ack (the core).
                leg_pulse = (($urandom % 2) == 0);
                d_addr = leg_a;
                if (r < 5) begin
                    d_we = 1'b0; d_line = 1'b0; leg_is_rd = 1'b1;
                    leg_exp = sh_word(leg_a);
                    n_leg_rd++;
                end else if (r < 9) begin
                    logic [DW-1:0] w, old;
                    logic [DW/8-1:0] st;
                    d_we = 1'b1; d_line = 1'b0; leg_is_rd = 1'b0;
                    w = {$urandom, $urandom, $urandom, $urandom};
                    st = (r == 8) ? 16'(($urandom % 65535) + 1) : '1;
                    d_wdata = w; d_wstrb = st;
                    old = sh_word(leg_a);
                    for (int b = 0; b < DW / 8; b++) if (st[b]) old[8*b +: 8] = w[8*b +: 8];
                    shadow[leg_a >> 4] = old;
                    n_leg_wr++;
                end else begin
                    // Full-line write: all zero (allocator init) or data.
                    logic [LW-1:0] l;
                    l = (($urandom % 2) == 0) ? '0
                        : {16{$urandom}};
                    d_we = 1'b1; d_line = 1'b1; leg_is_rd = 1'b0;
                    d_wline = l; d_wstrb = '1; d_wdata = l[DW-1:0];
                    d_addr = {leg_a[AW-1:6], 6'd0};
                    for (int b = 0; b < LW / DW; b++)
                        shadow[(d_addr >> 4) + b] = l[b*DW +: DW];
                    n_leg_wr++;
                end
            end

            #1;
            // ---- grant decision for the edge ahead ----
            if (nb_req && nb_gnt) begin
                granted = 1'b1;
                touched[nb_addr >> 6] = 1'b1;
                if (nb_pf) n_nb_pf++;
                else begin
                    if (nb_out[nb_id]) fail("reused busy id");
                    nb_out[nb_id] = 1'b1;
                    nb_exp[nb_id] = sh_line(nb_addr);
                    nb_exp_addr[nb_id] = nb_addr;
                    n_nb_rd++;
                end
            end
            @(posedge clk);
            #1;
            if (granted) nb_req = 1'b0;
            if (leg_pulse) d_req = 1'b0;
            @(negedge clk);
            if (draining && !leg_busy && l1d_idle) begin
                int k;
                k = 0;
                for (int i = 0; i < 16; i++) k += nb_out[i];
                if (k == 0 && !nb_req) break;
            end
        end

        for (int i = 0; i < 16; i++) if (nb_out[i]) fail($sformatf("id %0d never answered", i));
        if (!l1d_idle) fail("L1D not idle after drain");

        // Read every touched line back through ordinary reads.
        foreach (touched[k]) begin
            for (int b = 0; b < 4; b++) begin
                logic [AW-1:0] a;
                int n;
                a = AW'(k << 6) + AW'(b * 16);
                d_req = 1'b1; d_we = 1'b0; d_line = 1'b0; d_addr = a;
                n = 0;
                @(negedge clk);
                while (!d_ack) begin
                    @(negedge clk);
                    n++;
                    if (n > 20000) begin
                        fail("final read timeout");
                        break;
                    end
                end
                if (d_rdata !== sh_word(a))
                    fail($sformatf("final %h: got %h want %h", a, d_rdata, sh_word(a)));
                d_req = 1'b0;
                @(negedge clk);
            end
        end

        $display("tb_mem_nb seed=%0d lat=%0d: ordinary %0d rd %0d wr, nb %0d rd %0d pf %0d acks, %0d cycles with both in flight",
                 seed, t_first, n_leg_rd, n_leg_wr, n_nb_rd, n_nb_pf, n_nb_ack, n_overlap);
        $display("  L1D hits %0d misses %0d writebacks %0d; L2 hits %0d misses %0d writebacks %0d",
                 l1d_hits, l1d_misses, l1d_wbs, l2_hits, l2_misses, l2_wbs);
        if (errors == 0 && n_nb_ack == n_nb_rd && n_overlap > 0 && l2_wbs > 0 && l1d_wbs > 0)
            $display("PASS: tb_mem_nb");
        else
            $display("FAIL: tb_mem_nb (%0d errors, acks %0d of %0d, overlap %0d)",
                     errors, n_nb_ack, n_nb_rd, n_overlap);
        $finish;
    end
endmodule
