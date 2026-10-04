// gc_shadow_check: shadow-heap use-after-free checker (planning/gc_plan.md
// §10.2 G5). Simulation only; instantiated by tb_container for both tops.
//
// One state bit per heap granule: FREE (in a free run that is not the
// current allocation run) or not. The sweep reports each free run on the
// engine's free_range port; S_GC_ENTER clears the map first, since every
// sweep reports the complete free set. When the allocator makes a run current
// (heap_limit changes, or heap_ptr moves back), the abandoned remainder of the
// old run becomes FREE and the new run stops being FREE. [heap_ptr, heap_limit) is always legal:
// STRACC and excore write there before the core adopts their cursor.
//
// Mutator accesses (core dmem port outside the GC states, which covers every
// core master and STRACC; excore slot port) to a FREE granule are fatal.
// +GC_SHADOW_SELFTEST=1 forces a check of the first freed granule after the
// first collection: the gate requires that it fires.
module gc_shadow_check #(
    parameter int GRANULES = PYCORE_HEAP_LIMIT >> 4
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        en_i,
    input  logic        gc_enter_i,
    input  logic        gc_done_i,
    input  logic        gc_state_i,
    input  logic        free_valid_i,
    input  logic [31:0] free_base_i,
    input  logic [31:0] free_len_i,
    input  logic [31:0] heap_ptr_i,
    input  logic [31:0] heap_limit_i,
    input  logic        core_req_i,
    input  logic        core_we_i,
    input  logic [31:0] core_addr_i,
    input  logic [31:0] pc_i,
    input  logic [7:0]  opcode_i,
    input  logic        ex_req_i,
    input  logic        ex_we_i,
    input  logic [31:0] ex_addr_i
);
    bit free_q [0:GRANULES-1];
    logic [31:0] prev_ptr, prev_limit;
    bit selftest;
    bit selftest_done;
    logic [31:0] selftest_addr;
    int unsigned checks;

    initial begin
        selftest = $test$plusargs("GC_SHADOW_SELFTEST=1");
        selftest_done = 1'b0;
        selftest_addr = '0;
        checks = 0;
        for (int g = 0; g < GRANULES; g++) free_q[g] = 1'b0;
    end

    task automatic set_range(input logic [31:0] base, input logic [31:0] len, input bit v);
        for (logic [31:0] a = base; a < base + len; a += 32'd16) begin
            if ((a >> 4) < GRANULES) free_q[a >> 4] = v;
        end
    endtask

    task automatic check(input string master, input logic [31:0] addr, input bit we);
        if ((addr >= PYCORE_HEAP_BASE) && (addr < PYCORE_HEAP_LIMIT) &&
            free_q[addr >> 4] && !((addr >= heap_ptr_i) && (addr < heap_limit_i))) begin
            $fatal(1, "[GC-SHADOW] use-after-free: master=%s %s addr=%h pc=%0d opcode=%0d",
                   master, we ? "write" : "read", addr, pc_i, opcode_i);
        end
        checks++;
    endtask

    // Simulation model: blocking updates of the shadow state are intended.
    /* verilator lint_off BLKSEQ */
    always @(posedge clk_i) begin
        if (rst_n_i && en_i) begin
            if (gc_enter_i) begin
                for (int g = 0; g < GRANULES; g++) free_q[g] = 1'b0;
            end
            if (free_valid_i) begin
                set_range(free_base_i, free_len_i, 1'b1);
                if (selftest && !selftest_done && (selftest_addr == 32'd0) &&
                    (free_len_i >= 32'd32) && (free_base_i + 32'd32 <= heap_ptr_i))
                    selftest_addr = free_base_i + 32'd16;
            end
            // A run becomes current when the limit moves, or when the cursor
            // moves back with the same limit (a popped run that ends where
            // the old one did; a _bi_heap_release rewind).
            if ((heap_limit_i != prev_limit) || (heap_ptr_i < prev_ptr)) begin
                if ((heap_limit_i != prev_limit) && (prev_limit > prev_ptr))
                    set_range(prev_ptr, prev_limit - prev_ptr, 1'b1);
                if (heap_limit_i > heap_ptr_i) set_range(heap_ptr_i, heap_limit_i - heap_ptr_i, 1'b0);
            end
            if (gc_done_i && (heap_limit_i > heap_ptr_i)) begin
                // Verify-only collections keep the current run.
                set_range(heap_ptr_i, heap_limit_i - heap_ptr_i, 1'b0);
            end
            if (core_req_i && !gc_state_i) check("core", core_addr_i, core_we_i);
            if (ex_req_i) check("excore", ex_addr_i, ex_we_i);
            if (selftest && !selftest_done && (selftest_addr != 32'd0) && !gc_state_i) begin
                selftest_done = 1'b1;
                $display("[GC-SHADOW] self-test: forcing a read of freed granule %h", selftest_addr);
                check("selftest", selftest_addr, 1'b0);
                $display("[GC-SHADOW] self-test did NOT fire");
            end
        end
        prev_ptr   <= heap_ptr_i;
        prev_limit <= heap_limit_i;
    end
    /* verilator lint_on BLKSEQ */
endmodule
