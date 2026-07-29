`include "pycore_defs.svh"

// Phase B testbench: excore_cpu + excore_mmio + a real pycore_mem_bank,
// running the assembled list_grow.s firmware against canned LIST_GROW and
// LIST_EXTEND trap messages driven directly onto the mailbox input ports
// (no trap_mailbox.sv / pycore integration yet -- that is Phase C).
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
    logic [4:0]   mb_trap_code;
    logic [31:0]  mb_pc;
    logic [7:0]   mb_opcode;
    logic [31:0]  mb_arg;
    logic [31:0]  mb_heap_ptr;
    logic [2:0]   mb_entry_count;
    logic [131:0] mb_entries [0:3];

    // ---- Result observation ----------------------------------------------
    logic         res_go;
    logic [3:0]   res_code;
    logic [4:0]   res_fatal_code;
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
        mb_entries[3]   = 132'h0;
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

    // Present a LIST_EXTEND trap (dst list + LIST/TUPLE iterable).
    task automatic run_list_extend(
        input logic [131:0] dst_entry,
        input logic [131:0] src_entry,
        input logic [31:0] heap_ptr,
        input int max_cycles
    );
        int i;
        mb_entries[0]  = dst_entry;
        mb_entries[1]  = src_entry;
        mb_entry_count = 3'd2;
        mb_heap_ptr    = heap_ptr;
        mb_trap_code   = TRAP_LIST_EXTEND;
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
        $error("[FAIL] timed out waiting for RES_GO (LIST_EXTEND)");
        $finish;
    endtask

    task automatic run_unknown_trap(input logic [4:0] code, input int max_cycles);
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

    localparam logic [3:0] TRAP_LIST_GROW      = 4'd9;
    localparam logic [3:0] TRAP_LIST_EXTEND    = 4'd10;
    localparam logic [3:0] TRAP_DICT_GROW      = 4'd11;
    localparam logic [3:0] TRAP_LIST_DELETE    = 4'd12;
    localparam logic [3:0] TRAP_SET_GROW       = 4'd13;
    localparam logic [3:0] RES_COMPLETED       = 4'd0;
    localparam logic [3:0] RES_FATAL           = 4'd2;

    // Present a LIST_DELETE trap (list + INT/BOOL index).
    task automatic run_list_delete(
        input logic [131:0] list_entry,
        input logic [131:0] key_entry,
        input logic [31:0]  heap_ptr,
        input int max_cycles
    );
        int i;
        mb_entries[0]  = list_entry;
        mb_entries[1]  = key_entry;
        mb_entry_count = 3'd2;
        mb_heap_ptr    = heap_ptr;
        mb_trap_code   = TRAP_LIST_DELETE;
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
        $error("[FAIL] timed out waiting for RES_GO (LIST_DELETE)");
        $finish;
    endtask

    // Present a DICT_GROW trap (dict + key + value).
    task automatic run_dict_grow(
        input logic [131:0] dict_entry,
        input logic [131:0] key_entry,
        input logic [131:0] val_entry,
        input logic [31:0]  heap_ptr,
        input int max_cycles
    );
        int i;
        mb_entries[0]  = dict_entry;
        mb_entries[1]  = key_entry;
        mb_entries[2]  = val_entry;
        mb_entry_count = 3'd3;
        mb_heap_ptr    = heap_ptr;
        mb_trap_code   = TRAP_DICT_GROW;
        mb_opcode      = 8'd38; // STORE_SUBSCR
        mb_arg         = 32'd0;
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
        $error("[FAIL] timed out waiting for RES_GO (DICT_GROW)");
        $finish;
    endtask

    // Present a SET_GROW trap (set + element).
    task automatic run_set_grow(
        input logic [131:0] set_entry,
        input logic [131:0] elem_entry,
        input logic [31:0]  heap_ptr,
        input int max_cycles
    );
        int i;
        mb_entries[0]  = set_entry;
        mb_entries[1]  = elem_entry;
        mb_entry_count = 3'd2;
        mb_heap_ptr    = heap_ptr;
        mb_trap_code   = TRAP_SET_GROW;
        mb_opcode      = 8'd107; // SET_ADD
        mb_arg         = 32'd1;
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
        $error("[FAIL] timed out waiting for RES_GO (SET_GROW)");
        $finish;
    endtask

    initial begin
        logic [31:0] obj_addr, old_buf, new_buf, src_addr, src_buf;
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

        // Multicycle hart is ~5 cycles/insn; copy+append needs headroom.
        run_list_grow(obj_addr, {4'd1, 128'd200}, new_buf, 20000);

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

        run_list_grow(obj_addr, {4'd1, 128'd42}, new_buf, 20000);

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

        run_list_grow(obj_addr, {4'd1, 128'd999}, new_buf, 20000);

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

        run_list_grow(obj_addr, {4'd1, 128'd7}, 32'h1F80, 20000);

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
        run_unknown_trap(4'd3, 20000); // PY_TRAP_DIV_ZERO is not LIST_GROW

        check(res_code == RES_FATAL, "scenario5: expected RES_FATAL");
        check(res_fatal_code == PY_TRAP_ILLEGAL_OPCODE,
              "scenario5: expected fatal_code == PY_TRAP_ILLEGAL_OPCODE");
        $display("PASS: scenario5 (unknown trap code -> FATAL(ILLEGAL_OPCODE))");

        // ------------------------------------------------------------------
        // Scenario 6: LIST_EXTEND from a distinct LIST; grow-to-fit.
        // dst cap=2/len=1 [100]; src len=2 [200,300]; need=3 → new_cap=4.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0700;
        old_buf  = 32'h0720;
        src_addr = 32'h0780;
        src_buf  = 32'h07A0;
        new_buf  = 32'h0800;
        poke_slot(obj_addr, {64'd2, 64'd1});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf, 128'd100);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(src_addr, {64'd2, 64'd2});          // src header {cap=2,len=2}
        poke_slot(src_addr + 16, {96'd0, src_buf});
        poke_slot(src_buf, 128'd200);
        poke_slot(src_buf + 16, {124'b0, 4'd1});
        poke_slot(src_buf + 32, 128'd300);
        poke_slot(src_buf + 48, {124'b0, 4'd1});

        run_list_extend(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {PY_TAG_LIST, {96{1'b0}}, src_addr},
            new_buf, 40000);

        check(res_code == RES_COMPLETED, "scenario6: expected RES_COMPLETED");
        check(res_pop_count == 3'd1, "scenario6: expected pop_count=1");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd3}, "scenario6: header should be {cap=4, len=3}");
        check(peek_slot(new_buf) == 128'd100, "scenario6: preserved dst[0]");
        check(peek_slot(new_buf + 32) == 128'd200, "scenario6: extended src[0]");
        check(peek_slot(new_buf + 64) == 128'd300, "scenario6: extended src[1]");
        $display("PASS: scenario6 (LIST_EXTEND list source, grow-to-fit)");

        // ------------------------------------------------------------------
        // Scenario 7: LIST_EXTEND from a TUPLE source.
        // dst cap=1/len=1 [7]; tuple (8, 9) at src_addr; need=3 → new_cap=4.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0900;
        old_buf  = 32'h0920;
        src_addr = 32'h0940; // tuple element base (inline, no header)
        new_buf  = 32'h0980;
        poke_slot(obj_addr, {64'd1, 64'd1});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf, 128'd7);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(src_addr, 128'd8);
        poke_slot(src_addr + 16, {124'b0, 4'd1});
        poke_slot(src_addr + 32, 128'd9);
        poke_slot(src_addr + 48, {124'b0, 4'd1});

        run_list_extend(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {PY_TAG_TUPLE, 64'd2, {32'd0, src_addr}},
            new_buf, 40000);

        check(res_code == RES_COMPLETED, "scenario7: expected RES_COMPLETED");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd3}, "scenario7: header should be {cap=4, len=3}");
        check(peek_slot(new_buf) == 128'd7, "scenario7: preserved dst[0]");
        check(peek_slot(new_buf + 32) == 128'd8, "scenario7: tuple elem0");
        check(peek_slot(new_buf + 64) == 128'd9, "scenario7: tuple elem1");
        $display("PASS: scenario7 (LIST_EXTEND tuple source)");

        // ------------------------------------------------------------------
        // Scenario 8: LIST_EXTEND self-extend.
        // dst cap=2/len=2 [11, 22]; extend with itself → [11,22,11,22], cap=4.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0A00;
        old_buf  = 32'h0A20;
        new_buf  = 32'h0A80;
        poke_slot(obj_addr, {64'd2, 64'd2});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf, 128'd11);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(old_buf + 32, 128'd22);
        poke_slot(old_buf + 48, {124'b0, 4'd1});

        run_list_extend(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            new_buf, 40000);

        check(res_code == RES_COMPLETED, "scenario8: expected RES_COMPLETED");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd4}, "scenario8: header should be {cap=4, len=4}");
        check(peek_slot(new_buf) == 128'd11, "scenario8: dst[0]");
        check(peek_slot(new_buf + 32) == 128'd22, "scenario8: dst[1]");
        check(peek_slot(new_buf + 64) == 128'd11, "scenario8: self-copy[0]");
        check(peek_slot(new_buf + 96) == 128'd22, "scenario8: self-copy[1]");
        $display("PASS: scenario8 (LIST_EXTEND self-extend)");

        // ------------------------------------------------------------------
        // Scenario 9: LIST_EXTEND with INT iterable → FATAL(TYPE).
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0B00;
        poke_slot(obj_addr, {64'd1, 64'd0});
        poke_slot(obj_addr + 16, 128'd0);

        run_list_extend(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {4'd1, 128'd5}, // INT
            32'h0B40, 20000);

        check(res_code == RES_FATAL, "scenario9: expected RES_FATAL");
        check(res_fatal_code == PY_TRAP_TYPE,
              "scenario9: expected fatal_code == PY_TRAP_TYPE");
        $display("PASS: scenario9 (LIST_EXTEND bad iterable -> FATAL(TYPE))");

        // ------------------------------------------------------------------
        // Scenario 9b: LIST_EXTEND in-place when capacity already sufficient.
        // dst cap=8/len=1 [50]; src [60,70]; need=3 <= 8 → no realloc.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0B80;
        old_buf  = 32'h0BA0;
        src_addr = 32'h0CC0;
        src_buf  = 32'h0CE0;
        poke_slot(obj_addr, {64'd8, 64'd1});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf, 128'd50);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(src_addr, {64'd2, 64'd2});
        poke_slot(src_addr + 16, {96'd0, src_buf});
        poke_slot(src_buf, 128'd60);
        poke_slot(src_buf + 16, {124'b0, 4'd1});
        poke_slot(src_buf + 32, 128'd70);
        poke_slot(src_buf + 48, {124'b0, 4'd1});

        run_list_extend(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {PY_TAG_LIST, {96{1'b0}}, src_addr},
            32'h0D00, 40000);

        check(res_code == RES_COMPLETED, "scenario9b: expected RES_COMPLETED");
        check(res_pop_count == 3'd1, "scenario9b: pop_count=1");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd8, 64'd3}, "scenario9b: header {cap=8, len=3}");
        check(peek_slot(obj_addr + 16) == {96'd0, old_buf},
              "scenario9b: ob_item unchanged");
        check(peek_slot(old_buf) == 128'd50, "scenario9b: dst[0]");
        check(peek_slot(old_buf + 32) == 128'd60, "scenario9b: dst[1]");
        check(peek_slot(old_buf + 64) == 128'd70, "scenario9b: dst[2]");
        $display("PASS: scenario9b (LIST_EXTEND in-place, capacity sufficient)");

        // ------------------------------------------------------------------
        // Scenario 9c: LIST_DELETE middle element (shift-down).
        // [10,20,30,40] del[1] → [10,30,40]; COMPLETED pop=2.
        // ------------------------------------------------------------------
        do_reset();
        obj_addr = 32'h0E00;
        old_buf  = 32'h0E20;
        poke_slot(obj_addr, {64'd4, 64'd4});
        poke_slot(obj_addr + 16, {96'd0, old_buf});
        poke_slot(old_buf, 128'd10);
        poke_slot(old_buf + 16, {124'b0, 4'd1});
        poke_slot(old_buf + 32, 128'd20);
        poke_slot(old_buf + 48, {124'b0, 4'd1});
        poke_slot(old_buf + 64, 128'd30);
        poke_slot(old_buf + 80, {124'b0, 4'd1});
        poke_slot(old_buf + 96, 128'd40);
        poke_slot(old_buf + 112, {124'b0, 4'd1});

        run_list_delete(
            {PY_TAG_LIST, {96{1'b0}}, obj_addr},
            {PY_TAG_INT, 128'd1},
            32'h0F00, 40000);

        check(res_code == RES_COMPLETED, "scenario9c: expected RES_COMPLETED");
        check(res_pop_count == 3'd2, "scenario9c: pop_count=2");
        hdr = peek_slot(obj_addr);
        check(hdr == {64'd4, 64'd3}, "scenario9c: header {cap=4, len=3}");
        check(peek_slot(old_buf) == 128'd10, "scenario9c: [0]=10");
        check(peek_slot(old_buf + 32) == 128'd30, "scenario9c: [1]=30");
        check(peek_slot(old_buf + 64) == 128'd40, "scenario9c: [2]=40");
        $display("PASS: scenario9c (LIST_DELETE middle shift)");

        // ------------------------------------------------------------------
        // Scenario 10: DICT_GROW from empty table; insert key=1 → value=99.
        // new_slots = 8; used becomes 1.
        // ------------------------------------------------------------------
        do_reset();
        begin
            logic [31:0] dobj, ntbl;
            dobj = 32'h0C00;
            ntbl = 32'h0C20;
            poke_slot(dobj, {64'd0, 64'd0});       // slots=0, used=0
            poke_slot(dobj + 16, 128'd0);          // table_ptr=0
            run_dict_grow(
                {PY_TAG_DICT, {96{1'b0}}, dobj},
                {PY_TAG_INT, 128'd1},
                {PY_TAG_INT, 128'd99},
                ntbl, 80000);
            check(res_code == RES_COMPLETED, "scenario10: DICT_GROW COMPLETED");
            check(res_pop_count == 3'd3, "scenario10: pop=3");
            check(res_push_count == 2'd0, "scenario10: push=0");
            check(peek_slot(dobj) == {64'd8, 64'd1}, "scenario10: header {8,1}");
            check(peek_slot(dobj + 16) == {96'd0, ntbl}, "scenario10: table_ptr");
            // key 1 hashes to slot 1
            check(peek_slot(ntbl + 64) == 128'd1, "scenario10: kval");
            check(peek_slot(ntbl + 80) == {124'b0, PY_TAG_INT}, "scenario10: ktag");
            check(peek_slot(ntbl + 96) == 128'd99, "scenario10: vval");
            check(peek_slot(ntbl + 112) == {124'b0, PY_TAG_INT}, "scenario10: vtag");
            $display("PASS: scenario10 (DICT_GROW empty -> insert)");
        end

        // ------------------------------------------------------------------
        // Scenario 11: SET_GROW — empty 0-slot set → insert element 7.
        // ------------------------------------------------------------------
        do_reset();
        begin
            logic [31:0] sobj, ntbl;
            logic [127:0] shdr, sptr;
            sobj = 32'h0D00;
            poke_slot(sobj, {64'd0, 64'd0});
            poke_slot(sobj + 16, 128'd0);
            run_set_grow(
                {4'd11, {96{1'b0}}, sobj},  // PY_TAG_SET
                {PY_TAG_INT, 128'd7},
                32'h0D40, 80000);
            check(res_code == RES_COMPLETED, "scenario11: SET_GROW COMPLETED");
            check(res_pop_count == 3'd1, "scenario11: pop=1");
            shdr = peek_slot(sobj);
            sptr = peek_slot(sobj + 16);
            ntbl = sptr[31:0];
            check(shdr[63:0] == 64'd1, "scenario11: used=1");
            check(shdr[127:64] >= 64'd8, "scenario11: slots>=8");
            check(ntbl != 32'd0, "scenario11: table_ptr set");
            $display("PASS: scenario11 (SET_GROW empty -> insert)");
        end

        check(!cpu_fault, "excore_cpu raised an internal fault (unsupported instruction)");

        $display("PASS: tb_excore — all scenarios green");
        $finish;
    end
endmodule
