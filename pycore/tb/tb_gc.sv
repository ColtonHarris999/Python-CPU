`include "pycore_defs.svh"

// tb_gc: unit testbench for pycore_gc (planning/gc_plan.md §10.2 G3).
//
// The engine drives the real pycore_mem_hier (L1D -> L2 -> RAM), so
// +CACHE_EN and +MEM_LATENCY behave as in the system. Plusargs:
//   +DMEM_HEX=<image>        heap image built by pycore/tools/gc_heapgen.py
//   +ROOTS=<file>            register roots, one "tag value-hex" per line
//   +DUMP=<prefix>           writes <prefix>.<n>.gcdump after collection n
//   +DYN_BASE= +HEAP_LIMIT= +SPILL_SP= +EXC_SP= +FRAME_DEPTH=   (decimal)
//   +RUNS=<n>                back-to-back collections (default 2: the second
//                            must see a clean bitmap and give the same result)
//   +STASH=1 +POISON=1 +ONCHIP=<entries> +STACK_LIMIT=<entries> +MUTANT=<n>
//   +RESCAN_LIMIT=<entries>
//   +CACHE_EN= +MEM_LATENCY= +MAX_CYCLES=
module tb_gc;
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    bit cache_en_sim;
    int mem_latency_sim;
    initial begin
        int ce;
        ce = int'(PYCORE_CACHE_EN);
        void'($value$plusargs("CACHE_EN=%d", ce));
        cache_en_sim = (ce != 0);
        mem_latency_sim = PYCORE_RAM_T_FIRST_CI;
        void'($value$plusargs("MEM_LATENCY=%d", mem_latency_sim));
    end

    logic         d_req, d_we, d_line, d_ack, d_fault;
    logic [31:0]  d_addr;
    logic [127:0] d_wdata, d_rdata;
    logic [PYCORE_LINE_BYTES*8-1:0] d_rline;
    logic [15:0]  d_wstrb;

    /* verilator lint_off PINCONNECTEMPTY */
    pycore_mem_hier #(
        .PROG_HEX(""), .CODE_RAM_HEX(""), .DMEM_HEX("")
    ) mem_hier (
        .clk_i(clk), .rst_n_i(rst_n),
        .cache_en_i(cache_en_sim), .t_first_i(mem_latency_sim),
        .imem_req_i(1'b0), .imem_we_i(1'b0), .imem_wstrb_i('0), .imem_addr_i('0),
        .imem_wdata_i('0), .imem_ack_o(), .imem_rdata_o(), .imem_fault_o(),
        .imem_line_o(), .imem_line_valid_o(),
        .dmem_req_i(d_req), .dmem_we_i(d_we), .dmem_line_i(d_line), .dmem_wstrb_i(d_wstrb),
        .dmem_addr_i(d_addr), .dmem_wdata_i(d_wdata), .dmem_wline_i('0),
        .dmem_ack_o(d_ack), .dmem_rdata_o(d_rdata), .dmem_fault_o(d_fault),
        .dmem_rdata_line_o(d_rline),
        .excore_req_i(1'b0), .excore_we_i(1'b0), .excore_wstrb_i('0), .excore_addr_i('0),
        .excore_wdata_i('0), .excore_ack_o(), .excore_rdata_o(), .excore_fault_o(),
        .flush_req_i(1'b0), .inv_req_i(1'b0), .flush_done_o(), .inv_done_o(), .l1d_idle_o(),
        .l1i_hit_count_o(), .l1i_miss_count_o(), .l1d_hit_count_o(), .l1d_miss_count_o(),
        .l1d_writeback_count_o(), .l1d_frame_hit_count_o(), .l1d_frame_miss_count_o(),
        .l2_hit_count_o(), .l2_miss_count_o(), .l2_writeback_count_o()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic         start, busy, done;
    logic [31:0]  cfg_dyn_base, cfg_heap_limit, cfg_spill_sp, cfg_exc_sp, cfg_frame_depth;
    logic [31:0]  cfg_keep_lo, cfg_keep_hi, cfg_rover_addr;
    logic         cfg_stash, cfg_poison;
    logic [31:0]  cfg_stack_limit, cfg_rescan_limit;
    logic [7:0]   cfg_onchip, cfg_mutant;
    logic         root_valid, roots_done, root_ready;
    logic [PYCORE_ENTRY_WIDTH-1:0] root_entry;
    logic [31:0]  live, free_b, lbase, lsize, rhead, runs, badk, resv, wild;
    logic [31:0]  run_onchip_n, run_ovf_head, run_peek_base, run_peek_size;
    logic         ovf, flt;
    logic [31:0]  mark_cyc, sweep_cyc, busy_mark, mark_x, spill_x, stack_hw, stash_cyc, objs, nroots;
    logic [31:0]  rescans;
    logic         fr_valid;
    logic [31:0]  fr_base, fr_len;

    pycore_gc gc (
        .clk_i(clk), .rst_n_i(rst_n), .start_i(start), .busy_o(busy), .done_o(done),
        .dyn_base_i(cfg_dyn_base), .heap_limit_i(cfg_heap_limit), .spill_sp_i(cfg_spill_sp),
        .exc_sp_i(cfg_exc_sp), .frame_depth_i(cfg_frame_depth),
        .stash_en_i(cfg_stash), .poison_en_i(cfg_poison), .line_wr_ok_i(1'b0), .zero_base_i(cfg_heap_limit), .keep_lo_i(cfg_keep_lo), .keep_hi_i(cfg_keep_hi), .rover_addr_i(cfg_rover_addr), .clean_skip_i(1'b0), .extra_roots_i(1'b1), .clean_busy_addr_o(), .clean_done_o(),
        .stack_limit_i(cfg_stack_limit), .onchip_limit_i(cfg_onchip),
        .rescan_limit_i(cfg_rescan_limit), .mutant_i(cfg_mutant),
        .root_valid_i(root_valid), .root_entry_i(root_entry), .roots_done_i(roots_done),
        .root_ready_o(root_ready),
        .req_o(d_req), .we_o(d_we), .line_o(d_line), .addr_o(d_addr),
        .wdata_o(d_wdata), .wstrb_o(d_wstrb),
        .ack_i(d_ack), .rdata_i(d_rdata), .rline_i(d_rline), .fault_i(d_fault),
        .cache_en_i(cache_en_sim),
        .live_bytes_o(live), .free_bytes_o(free_b), .largest_base_o(lbase),
        .largest_size_o(lsize), .run_head_o(rhead), .runs_o(runs),
        .run_onchip_n_o(run_onchip_n), .run_overflow_head_o(run_ovf_head),
        .run_peek_idx_i(10'd0), .run_peek_base_o(run_peek_base),
        .run_peek_size_o(run_peek_size),
        .stack_overflow_o(ovf), .fault_o(flt), .bad_kind_o(badk), .reserved_tag_o(resv),
        .wild_ptr_o(wild), .mark_cyc_o(mark_cyc), .sweep_cyc_o(sweep_cyc),
        .port_busy_mark_o(busy_mark), .mark_xacts_o(mark_x), .spill_xacts_o(spill_x),
        .stack_hw_o(stack_hw), .stash_cyc_o(stash_cyc), .objects_o(objs), .roots_o(nroots),
        .rescans_o(rescans),
        .dirty_hi_o(),
        .free_range_valid_o(fr_valid), .free_range_base_o(fr_base), .free_range_len_o(fr_len)
    );

    `define GC_MEMH mem_hier
    `include "gc_tb_util.svh"

    logic [3:0]   rt_tag [0:1023];
    logic [127:0] rt_val [0:1023];
    int           n_roots;

    initial begin
        string roots_path, dump_prefix, path;
        int fd, rc, tg, runs_n, max_cycles, cyc, v;
        logic [127:0] val;
        start = 1'b0; root_valid = 1'b0; roots_done = 1'b0; root_entry = '0;
        cfg_dyn_base = PYCORE_HEAP_BASE; cfg_heap_limit = PYCORE_HEAP_LIMIT;
        cfg_keep_lo = '0; cfg_keep_hi = '0; cfg_rover_addr = '0;
        cfg_spill_sp = PYCORE_RF_SPILL_BASE; cfg_exc_sp = PYCORE_EXC_STACK_BASE;
        cfg_frame_depth = 0; cfg_stash = 1'b1; cfg_poison = 1'b0;
        cfg_stack_limit = 0; cfg_rescan_limit = 0; cfg_onchip = 0; cfg_mutant = 0;
        runs_n = 2; max_cycles = 20000000;
        if ($value$plusargs("DYN_BASE=%d", v)) cfg_dyn_base = v;
        if ($value$plusargs("HEAP_LIMIT=%d", v)) cfg_heap_limit = v;
        if ($value$plusargs("SPILL_SP=%d", v)) cfg_spill_sp = v;
        if ($value$plusargs("EXC_SP=%d", v)) cfg_exc_sp = v;
        if ($value$plusargs("FRAME_DEPTH=%d", v)) cfg_frame_depth = v;
        if ($value$plusargs("STASH=%d", v)) cfg_stash = (v != 0);
        if ($value$plusargs("POISON=%d", v)) cfg_poison = (v != 0);
        if ($value$plusargs("STACK_LIMIT=%d", v)) cfg_stack_limit = v;
        if ($value$plusargs("RESCAN_LIMIT=%d", v)) cfg_rescan_limit = v;
        if ($value$plusargs("ONCHIP=%d", v)) cfg_onchip = 8'(v);
        if ($value$plusargs("MUTANT=%d", v)) cfg_mutant = 8'(v);
        if ($value$plusargs("KEEP_LO=%d", v)) cfg_keep_lo = v;
        if ($value$plusargs("KEEP_HI=%d", v)) cfg_keep_hi = v;
        if ($value$plusargs("ROVER_ADDR=%d", v)) cfg_rover_addr = v;
        void'($value$plusargs("RUNS=%d", runs_n));
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        dump_prefix = "build/tb_gc/out";
        void'($value$plusargs("DUMP=%s", dump_prefix));
        n_roots = 0;
        if ($value$plusargs("ROOTS=%s", roots_path)) begin
            fd = $fopen(roots_path, "r");
            if (fd == 0) $fatal(1, "tb_gc: cannot open ROOTS=%s", roots_path);
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%d %h\n", tg, val);
                if (rc == 2) begin
                    rt_tag[n_roots] = 4'(tg);
                    rt_val[n_roots] = val;
                    n_roots++;
                end
            end
            $fclose(fd);
        end

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (int run = 0; run < runs_n; run++) begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            for (int i = 0; i < n_roots; i++) begin
                root_valid = 1'b1;
                root_entry = {rt_tag[i], rt_val[i]};
                @(posedge clk);
                while (!root_ready) @(posedge clk);
                @(negedge clk);
            end
            root_valid = 1'b0;
            roots_done = 1'b1;
            cyc = 0;
            while (!done) begin
                @(posedge clk);
                cyc++;
                if (cyc > max_cycles) $fatal(1, "tb_gc: collection %0d did not finish in %0d cycles", run, max_cycles);
            end
            @(negedge clk);
            roots_done = 1'b0;
            path = $sformatf("%s.%0d.gcdump", dump_prefix, run);
            fd = $fopen(path, "w");
            if (fd == 0) $fatal(1, "tb_gc: cannot open %s", path);
            $fwrite(fd, "# pycore-gc-dump v1\n");
            $fwrite(fd, "meta collection %0d\nmeta dyn_base %0d\nmeta heap_limit %0d\n", run, cfg_dyn_base, cfg_heap_limit);
            $fwrite(fd, "meta spill_sp %0d\nmeta exc_sp %0d\nmeta frame_depth %0d\n", cfg_spill_sp, cfg_exc_sp, cfg_frame_depth);
            $fwrite(fd, "meta run_head %0d\nmeta live %0d\nmeta free %0d\nmeta largest %0d\nmeta largest_base %0d\nmeta runs %0d\n",
                    rhead, live, free_b, lsize, lbase, runs);
            $fwrite(fd, "meta roots %0d\nmeta objects %0d\nmeta stack_hw %0d\nmeta overflow %0d\n", nroots, objs, stack_hw, ovf);
            $fwrite(fd, "meta bad_kind %0d\nmeta reserved %0d\nmeta wild %0d\nmeta fault %0d\nmeta stash_en %0d\n",
                    badk, resv, wild, flt, cfg_stash);
            $fwrite(fd, "meta stack_limit %0d\nmeta rescan_limit %0d\nmeta rescans %0d\n",
                    gc.stack_limit_r, gc.rescan_limit_r, rescans);
            $fwrite(fd, "meta onchip %0d\n", gc.onchip_limit_r);
            $fwrite(fd, "meta keep_lo %0d\nmeta keep_hi %0d\nmeta rover_addr %0d\nmeta rover %0d\nmeta onchip_runs %0d\n",
                    gc.keep_lo_r, gc.keep_hi_r, gc.rover_addr_r, gc.run_rover_r, gc.run_onchip_n_r);
            $fwrite(fd, "meta mark_cyc %0d\nmeta sweep_cyc %0d\nmeta port_busy_mark %0d\nmeta mark_xacts %0d\nmeta spill_xacts %0d\nmeta stash_cyc %0d\nmeta pause %0d\n",
                    mark_cyc, sweep_cyc, busy_mark, mark_x, spill_x, stash_cyc, cyc);
            for (int i = 0; i < n_roots; i++) $fwrite(fd, "root %0d %0h\n", rt_tag[i], rt_val[i]);
            gc_dump_memory(fd, cfg_heap_limit, cfg_frame_depth, cfg_spill_sp);
            begin
                automatic int n;
                automatic logic [31:0] slot, nxt;
                n = int'(gc.run_onchip_n_r);
                for (int i = 0; i < n; i++) begin
                    slot = PYCORE_GC_RUN_TABLE + (i << 4);
                    nxt = (i + 1 < n) ? (slot + 32'd16)
                        : gc.run_overflow_head_r;
                    $fwrite(fd, "mem %0h %0h\n", slot,
                            {PYCORE_GC_FREE_MAGIC, gc.run_size_q[i], nxt,
                             gc.run_base_q[i]});
                end
            end
            $fclose(fd);
            $display("TB_GC run=%0d live=%0d free=%0d largest=%0d runs=%0d objects=%0d stack_hw=%0d rescans=%0d pause=%0d mark_cyc=%0d sweep_cyc=%0d port_busy_mark=%0d overflow=%0d",
                     run, live, free_b, lsize, runs, objs, stack_hw, rescans, cyc, mark_cyc, sweep_cyc, busy_mark, ovf);
            if (flt) $fatal(1, "tb_gc: memory fault during collection");
            if (ovf) break;
        end
        $display("TB_GC PASS");
        $finish;
    end
endmodule
