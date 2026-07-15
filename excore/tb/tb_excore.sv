`include "pycore_defs.svh"

// Phase B testbench: excore_cpu + excore_mmio + a real pycore_mem_bank,
// running the assembled list_grow.s firmware against five canned trap
// messages driven directly onto the mailbox input ports (no trap_mailbox.sv
// / pycore integration yet -- that is Phase C).
//
// pycore_mem_bank is configured as a single 8 KB block (BLOCK_SHIFT=13,
// BLOCK_COUNT=1) covering the whole heap [0, PYCORE_HEAP_LIMIT), so scenario
// setup/verification can poke/peek `mem_bank.gen_block[0].blk.mem[...]`
// directly instead of arbitrating a second bus master.
//
// Scenario capacities reconcile the task text's "cap 1 -> 4" against the
// doubling formula `new_cap = cap ? cap<<1 : 4` (B.4): starting capacity 2
// (not 1) produces exactly a "-> 4" result while remaining faithful to the
// documented doubling rule; "cap 0 -> 4" and "cap 4 -> 8" match literally.
module tb_excore #(
    parameter string FW_HEX = "build/excore_fw/list_grow.hex"
);
    localparam int DATA_W = 128;

    logic clk;
    logic rst_n;

    // ---- excore_cpu <-> excore_mmio (CPU-facing bus) --------------------
    logic         mmio_req, mmio_we;
    logic [31:0]  mmio_addr, mmio_wdata, mmio_rdata;
    logic         mmio_ack;
    logic         cpu_fault;
    logic [31:0]  cpu_fault_pc;

    excore_cpu #(
        .FW_HEX(FW_HEX)
    ) cpu (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .mmio_req_o(mmio_req),
        .mmio_we_o(mmio_we),
        .mmio_addr_o(mmio_addr),
        .mmio_wdata_o(mmio_wdata),
        .mmio_ack_i(mmio_ack),
        .mmio_rdata_i(mmio_rdata),
        .fault_o(cpu_fault),
        .fault_pc_o(cpu_fault_pc)
    );

    // ---- Mailbox stimulus (driven directly by this TB) ------------------
    logic         mb_trap_pending;
    logic [3:0]   mb_trap_code;
    logic [31:0]  mb_pc;
    logic [7:0]   mb_opcode;
    logic [31:0]  mb_arg;
    logic [31:0]  mb_heap_ptr;
    logic [2:0]   mb_entry_count;
    logic [131:0] mb_entries [0:2];

    // ---- Result observation ----------------------------------------------
    logic         res_go;
    logic [3:0]   res_code, res_fatal_code;
    logic [2:0]   res_pop_count;
    logic [1:0]   res_push_count;
    logic [31:0]  res_heap_ptr;
    logic [131:0] res_entries [0:1];

    // ---- Slot port (excore_mmio <-> pycore_mem_bank) ---------------------
    logic         sp_req, sp_we;
    logic [31:0]  sp_addr;
    logic [127:0] sp_wdata, sp_rdata;
    logic         sp_ack, sp_fault;

    excore_mmio dut_mmio (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cpu_req_i(mmio_req),
        .cpu_we_i(mmio_we),
        .cpu_addr_i(mmio_addr),
        .cpu_wdata_i(mmio_wdata),
        .cpu_ack_o(mmio_ack),
        .cpu_rdata_o(mmio_rdata),
        .mb_trap_pending_i(mb_trap_pending),
        .mb_trap_code_i(mb_trap_code),
        .mb_pc_i(mb_pc),
        .mb_opcode_i(mb_opcode),
        .mb_arg_i(mb_arg),
        .mb_heap_ptr_i(mb_heap_ptr),
        .mb_entry_count_i(mb_entry_count),
        .mb_entries_i(mb_entries),
        .res_go_o(res_go),
        .res_code_o(res_code),
        .res_fatal_code_o(res_fatal_code),
        .res_pop_count_o(res_pop_count),
        .res_push_count_o(res_push_count),
        .res_heap_ptr_o(res_heap_ptr),
        .res_entries_o(res_entries),
        .sp_req_o(sp_req),
        .sp_we_o(sp_we),
        .sp_addr_o(sp_addr),
        .sp_wdata_o(sp_wdata),
        .sp_ack_i(sp_ack),
        .sp_rdata_i(sp_rdata),
        .sp_fault_i(sp_fault)
    );

    pycore_mem_bank #(
        .DATA_WIDTH(DATA_W),
        .ADDR_WIDTH(32),
        .BLOCK_SHIFT(13),   // 8 KB single block == PYCORE_HEAP_LIMIT
        .BLOCK_COUNT(1),
        .READ_ONLY(0),
        .INIT_HEX("")
    ) mem_bank (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .req_i(sp_req),
        .we_i(sp_we),
        .addr_i(sp_addr),
        .wdata_i(sp_wdata),
        .ack_o(sp_ack),
        .rdata_o(sp_rdata),
        .fault_o(sp_fault)
    );

    always #5 clk = ~clk;

    // Counts every slot-port read/write request the excore issues; reset
    // per scenario to verify e.g. "no copy reads issued" for a cap-0 list.
    int unsigned read_count, write_count;
    always @(posedge clk) begin
        if (sp_req && !sp_we) read_count  <= read_count + 1;
        if (sp_req && sp_we)  write_count <= write_count + 1;
    end

    task automatic poke_slot(input logic [31:0] addr, input logic [127:0] data);
        mem_bank.gen_block[0].blk.mem[addr[12:4]] = data;
    endtask

    function automatic logic [127:0] peek_slot(input logic [31:0] addr);
        peek_slot = mem_bank.gen_block[0].blk.mem[addr[12:4]];
    endfunction

    task automatic check(input bit condition, input string message);
        if (!condition) begin
            $error("[FAIL] %s", message);
            $finish;
        end
    endtask

    task automatic do_reset();
        rst_n = 1'b0;
        mb_trap_pending = 1'b0;
        mb_trap_code    = 4'h0;
        mb_pc           = 32'h0;
        mb_opcode       = 8'h0;
        mb_arg          = 32'h0;
        mb_heap_ptr     = 32'h0;
        mb_entry_count  = 3'h0;
        mb_entries[0]   = 132'h0;
        mb_entries[1]   = 132'h0;
        mb_entries[2]   = 132'h0;
        read_count      = 0;
        write_count     = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    endtask

    // Present a LIST_GROW trap (list handle + element) and wait for RES_GO.
    task automatic run_list_grow(
        input logic [31:0] obj_addr,
        input logic [131:0] element,
        input logic [31:0] heap_ptr,
        input int max_cycles
    );
        int i;
        mb_entries[0]  = {PY_TAG_LIST, {96{1'b0}}, obj_addr};
        mb_entries[1]  = element;
        mb_entry_count = 3'd2;
        mb_heap_ptr    = heap_ptr;
        mb_trap_code   = TRAP_LIST_GROW;
        @(negedge clk);
        mb_trap_pending = 1'b1;

        for (i = 0; i < max_cycles; i++) begin
            @(posedge clk);
            if (res_go) begin
                @(negedge clk);
                mb_trap_pending = 1'b0;
                return;
            end
        end
        $error("[FAIL] timed out waiting for RES_GO (LIST_GROW)");
        $finish;
    endtask

    task automatic run_unknown_trap(input logic [3:0] code, input int max_cycles);
        int i;
        mb_entry_count = 3'd0;
        mb_trap_code   = code;
        @(negedge clk);
        mb_trap_pending = 1'b1;

        for (i = 0; i < max_cycles; i++) begin
            @(posedge clk);
            if (res_go) begin
                @(negedge clk);
                mb_trap_pending = 1'b0;
                return;
            end
        end
        $error("[FAIL] timed out waiting for RES_GO (unknown trap)");
        $finish;
    endtask

    localparam logic [3:0] TRAP_LIST_GROW = 4'd9;
    localparam logic [3:0] RES_COMPLETED  = 4'd0;
    localparam logic [3:0] RES_FATAL      = 4'd2;

    initial begin
        logic [31:0] obj_addr, old_buf, new_buf;
        logic [127:0] hdr;

        clk = 1'b0;

        // ------------------------------------------------------------------
        // Scenario 1: cap 2 -> 4, one element preserved + one appended.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0400;
        old_buf  = 32'h0420;
        new_buf  = 32'h0460; // obj(32B) + old buffer (cap=2 * 32B = 64B)
        poke_slot(obj_addr, {64'd2, 64'd1});          // header {cap=2, len=1}
        poke_slot(obj_addr + 16, {96'd0, old_buf});   // ob_item
        poke_slot(old_buf, 128'd100);                 // element0 value
        poke_slot(old_buf + 16, {124'b0, 4'd1});      // element0 tag (INT)

        run_list_grow(obj_addr, {4'd1, 128'd200}, new_buf, 2000);

        check(res_code == RES_COMPLETED, "scenario1: expected RES_COMPLETED");
        check(res_pop_count == 3'd1, "scenario1: expected pop_count=1");
        check(res_push_count == 2'd0, "scenario1: expected push_count=0");
        check(res_heap_ptr == new_buf + 32'd128,
              "scenario1: RES_HEAP_PTR should be new_buf + new_cap*32 (4*32)");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd2}, "scenario1: header should be {cap=4, len=2}");
        check(peek_slot(obj_addr + 16) == {96'd0, new_buf}, "scenario1: ob_item should point at new_buf");
        check(peek_slot(new_buf) == 128'd100, "scenario1: preserved element0 value mismatch");
        check(peek_slot(new_buf + 16) == {124'b0, 4'd1}, "scenario1: preserved element0 tag mismatch");
        check(peek_slot(new_buf + 32) == 128'd200, "scenario1: appended element1 value mismatch");
        check(peek_slot(new_buf + 48) == {124'b0, 4'd1}, "scenario1: appended element1 tag mismatch");
        $display("PASS: scenario1 (cap 2 -> 4, preserve + append)");

        // ------------------------------------------------------------------
        // Scenario 2: cap 0 -> 4, no copy reads issued.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0500;
        new_buf  = 32'h0520;
        poke_slot(obj_addr, {64'd0, 64'd0});         // header {cap=0, len=0}
        poke_slot(obj_addr + 16, 128'd0);             // ob_item = 0

        run_list_grow(obj_addr, {4'd1, 128'd42}, new_buf, 2000);

        check(res_code == RES_COMPLETED, "scenario2: expected RES_COMPLETED");
        // Exactly 2 reads: the header and the ob_item slot. Zero additional
        // reads from the copy loop (len=0 skips it entirely).
        check(read_count == 2, $sformatf(
              "scenario2: expected exactly 2 slot-port reads (header+ob_item), got %0d",
              read_count));
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd1}, "scenario2: header should be {cap=4, len=1}");
        check(peek_slot(obj_addr + 16) == {96'd0, new_buf}, "scenario2: ob_item should point at new_buf");
        check(peek_slot(new_buf) == 128'd42, "scenario2: appended element0 value mismatch");
        check(peek_slot(new_buf + 16) == {124'b0, 4'd1}, "scenario2: appended element0 tag mismatch");
        $display("PASS: scenario2 (cap 0 -> 4, no copy reads issued)");

        // ------------------------------------------------------------------
        // Scenario 3: cap 4 -> 8, mixed-tag elements preserved bit-exactly.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0600;
        old_buf  = 32'h0620;
        new_buf  = 32'h06A0; // obj(32B) + old buffer (cap=4 * 32B = 128B)
        poke_slot(obj_addr, {64'd4, 64'd3});          // header {cap=4, len=3}
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf,       128'hDEADBEEF_CAFEBABE_11223344_55667788); // INT
        poke_slot(old_buf + 16,  {124'b0, 4'd1});
        poke_slot(old_buf + 32,  128'h6000000000000000_0000000000000078);  // SHORT_STR
        poke_slot(old_buf + 48,  {124'b0, 4'd6});
        poke_slot(old_buf + 64,  {64'd0, 32'd0, 32'h0000_0700});           // nested LIST handle
        poke_slot(old_buf + 80,  {124'b0, 4'd10});

        run_list_grow(obj_addr, {4'd1, 128'd999}, new_buf, 2000);

        check(res_code == RES_COMPLETED, "scenario3: expected RES_COMPLETED");
        check(res_heap_ptr == new_buf + 32'd256,
              "scenario3: RES_HEAP_PTR should be new_buf + new_cap*32 (8*32)");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd8, 64'd4}, "scenario3: header should be {cap=8, len=4}");
        check(peek_slot(new_buf) == 128'hDEADBEEF_CAFEBABE_11223344_55667788,
              "scenario3: INT element not preserved bit-exactly");
        check(peek_slot(new_buf + 16) == {124'b0, 4'd1}, "scenario3: INT tag mismatch");
        check(peek_slot(new_buf + 32) == 128'h6000000000000000_0000000000000078,
              "scenario3: SHORT_STR element not preserved bit-exactly");
        check(peek_slot(new_buf + 48) == {124'b0, 4'd6}, "scenario3: SHORT_STR tag mismatch");
        check(peek_slot(new_buf + 64) == {64'd0, 32'd0, 32'h0000_0700},
              "scenario3: nested LIST handle not preserved bit-exactly");
        check(peek_slot(new_buf + 80) == {124'b0, 4'd10}, "scenario3: nested LIST tag mismatch");
        check(peek_slot(new_buf + 96) == 128'd999, "scenario3: appended element value mismatch");
        check(peek_slot(new_buf + 112) == {124'b0, 4'd1}, "scenario3: appended element tag mismatch");
        $display("PASS: scenario3 (cap 4 -> 8, mixed tags preserved bit-exactly)");

        // ------------------------------------------------------------------
        // Scenario 4: OOM -> FATAL(MEM_FAULT), memory untouched.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h1F00;
        old_buf  = 32'h1F20;
        // new_cap would be 8 (doubling from 4); 8*32=256B from a heap_ptr
        // near the limit overflows PYCORE_HEAP_LIMIT (0x2000).
        poke_slot(obj_addr, {64'd4, 64'd2});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf,      128'd1);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(old_buf + 32, 128'd2);
        poke_slot(old_buf + 48, {124'b0, 4'd1});

        run_list_grow(obj_addr, {4'd1, 128'd7}, 32'h1F80, 2000);

        check(res_code == RES_FATAL, "scenario4: expected RES_FATAL");
        check(res_fatal_code == PY_TRAP_MEM_FAULT,
              "scenario4: expected fatal_code == PY_TRAP_MEM_FAULT");
        // Memory must be untouched: the OOM check happens before any write.
        check(peek_slot(obj_addr) == {64'd4, 64'd2}, "scenario4: header was mutated on OOM");
        check(peek_slot(obj_addr + 16) == {96'd0, old_buf}, "scenario4: ob_item was mutated on OOM");
        check(peek_slot(old_buf) == 128'd1, "scenario4: old buffer element0 was mutated on OOM");
        check(peek_slot(old_buf + 32) == 128'd2, "scenario4: old buffer element1 was mutated on OOM");
        check(write_count == 0, "scenario4: no slot-port write should have been issued on OOM");
        $display("PASS: scenario4 (OOM -> FATAL(MEM_FAULT), memory untouched)");

        // ------------------------------------------------------------------
        // Scenario 5: unknown trap code -> FATAL(ILLEGAL_OPCODE).
        // ------------------------------------------------------------------
        do_reset();
        run_unknown_trap(4'd3, 2000); // PY_TRAP_DIV_ZERO is not LIST_GROW

        check(res_code == RES_FATAL, "scenario5: expected RES_FATAL");
        check(res_fatal_code == PY_TRAP_ILLEGAL_OPCODE,
              "scenario5: expected fatal_code == PY_TRAP_ILLEGAL_OPCODE");
        $display("PASS: scenario5 (unknown trap code -> FATAL(ILLEGAL_OPCODE))");

        check(!cpu_fault, "excore_cpu raised an internal fault (unsupported instruction)");

        $display("PASS: tb_excore — all 5 scenarios green");
        $finish;
    end
endmodule
