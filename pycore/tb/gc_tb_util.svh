// Shared GC testbench helpers (planning/gc_plan.md §6.1 "coherent dump").
//
// Include inside a testbench module after defining GC_MEMH as the
// hierarchical path of the pycore_mem_hier instance, e.g.
//   `define GC_MEMH g_dut.dut.mem_hier
//   `include "gc_tb_util.svh"
//
// With CACHE_EN=1 the RAM model is stale (L1D and L2 are write-back), so
// gc_peek reads each 16 B word from the first level that holds its line:
// L1D, then L2, then RAM. L1D is never older than L2 (the only writer that
// bypasses it, excore, runs only after an L1D writeback+invalidate), so the
// first valid copy is the architectural value.

localparam int GCTB_OFF_W   = $clog2(PYCORE_LINE_BYTES);
localparam int GCTB_L1D_SET = $clog2(PYCORE_L1D_SIZE_BYTES / (PYCORE_LINE_BYTES * PYCORE_L1D_WAYS));
localparam int GCTB_L2_SET  = $clog2(PYCORE_L2_SIZE_BYTES / (PYCORE_LINE_BYTES * PYCORE_L2_WAYS));

function automatic logic [127:0] gc_peek(input logic [31:0] addr);
    logic [127:0] w;
    logic         hit;
    logic [GCTB_L1D_SET-1:0] s1;
    logic [GCTB_L2_SET-1:0]  s2;
    logic [1:0]   wi;
    s1 = addr[GCTB_OFF_W +: GCTB_L1D_SET];
    s2 = addr[GCTB_OFF_W +: GCTB_L2_SET];
    wi = addr[GCTB_OFF_W-1:4];
    hit = 1'b0;
    w = '0;
    for (int way = 0; way < PYCORE_L1D_WAYS; way++) begin
        if (!hit && `GC_MEMH.l1d.valid_q[s1][way] &&
            (`GC_MEMH.l1d.tag_q[s1][way] == addr[31:GCTB_OFF_W+GCTB_L1D_SET])) begin
            w = `GC_MEMH.l1d.data_q[s1][way][wi*128 +: 128];
            hit = 1'b1;
        end
    end
    for (int way = 0; way < PYCORE_L2_WAYS; way++) begin
        if (!hit && `GC_MEMH.l2.valid_q[s2][way] &&
            (`GC_MEMH.l2.tag_q[s2][way] == addr[31:GCTB_OFF_W+GCTB_L2_SET])) begin
            w = `GC_MEMH.l2.data_q[s2][way][wi*128 +: 128];
            hit = 1'b1;
        end
    end
    if (!hit) w = `GC_MEMH.ram.data_mem[addr >> 4];
    return w;
endfunction

// Write every non-zero word of [lo, hi) as "mem <addr> <word>".
task automatic gc_dump_region(input int fd, input logic [31:0] lo, input logic [31:0] hi);
    logic [127:0] w;
    for (logic [31:0] a = lo; a < hi; a += 32'd16) begin
        w = gc_peek(a);
        if (w != '0) $fwrite(fd, "mem %0h %0h\n", a, w);
    end
endtask

// The regions a collector dump needs: the heap (with the boot record below
// it), the exception arena (with the native table and StopIteration
// sidecar), the live frames, the RF spill prefix, the root stash, and the
// static prune map, and compiler-cleanup descriptor used to account for the
// two dictionary headers the idle cleanup pass premarks manually.
task automatic gc_dump_memory(input int fd, input logic [31:0] heap_limit,
                              input logic [31:0] frame_depth,
                              input logic [31:0] spill_sp);
    logic [31:0] stash_n;
    gc_dump_region(fd, PYCORE_BOOT_RECORD_ADDR, heap_limit);
    gc_dump_region(fd, PYCORE_GC_COMPILER_CLEANUP,
                   PYCORE_GC_COMPILER_CLEANUP + PYCORE_GC_COMPILER_CLEANUP_BYTES);
    gc_dump_region(fd, PYCORE_GC_STATIC_MAP, PYCORE_GC_STATIC_MAP + PYCORE_GC_STATIC_MAP_BYTES);
    gc_dump_region(fd, PYCORE_GC_EXTRA_ROOTS,
                   PYCORE_GC_EXTRA_ROOTS + (PYCORE_GC_EXTRA_ROOTS_COUNT << 5));
    gc_dump_region(fd, PYCORE_GC_RUN_TABLE, PYCORE_GC_RUN_TABLE + PYCORE_GC_RUN_TABLE_BYTES);
    gc_dump_region(fd, PYCORE_EXC_STACK_BASE, PYCORE_EXC_STACK_BASE + PYCORE_EXC_STACK_BYTES);
    gc_dump_region(fd, PYCORE_FRAME_STACK_BASE, PYCORE_FRAME_STACK_BASE + (frame_depth << 5));
    gc_dump_region(fd, PYCORE_RF_SPILL_BASE, spill_sp);
    stash_n = gc_peek(PYCORE_GC_ROOT_STASH)[31:0];
    if (stash_n > 32'd511) stash_n = 32'd511;
    gc_dump_region(fd, PYCORE_GC_ROOT_STASH, PYCORE_GC_ROOT_STASH + 32'd16 + (stash_n << 5));
endtask
