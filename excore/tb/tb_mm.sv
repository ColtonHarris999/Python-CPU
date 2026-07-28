`include "pycore_defs.svh"

// Layer-B TB for the firmware memory manager (mm.s) via mm_test.s harness.
module tb_mm #(
    parameter string FW_HEX = "build/excore_fw/mm_test.hex"
);
    localparam int DATA_W = 128;

    logic clk;
    logic rst_n;

    logic         mmio_req, mmio_we;
    logic [31:0]  mmio_addr, mmio_wdata, mmio_rdata;
    logic         mmio_ack;
    logic         cpu_fault;
    logic [31:0]  cpu_fault_pc;

    excore_cpu #(.FW_HEX(FW_HEX)) cpu (
        .clk_i(clk), .rst_n_i(rst_n),
        .mmio_req_o(mmio_req), .mmio_we_o(mmio_we),
        .mmio_addr_o(mmio_addr), .mmio_wdata_o(mmio_wdata),
        .mmio_ack_i(mmio_ack), .mmio_rdata_i(mmio_rdata),
        .fault_o(cpu_fault), .fault_pc_o(cpu_fault_pc)
    );

    logic         mb_trap_pending;
    logic [3:0]   mb_trap_code;
    logic [31:0]  mb_pc, mb_arg, mb_heap_ptr;
    logic [7:0]   mb_opcode;
    logic [2:0]   mb_entry_count;
    logic [131:0] mb_entries [0:2];

    logic         res_go;
    logic [3:0]   res_code, res_fatal_code;
    logic [2:0]   res_pop_count;
    logic [1:0]   res_push_count;
    logic [31:0]  res_heap_ptr;
    logic [131:0] res_entries [0:1];

    logic         sp_req, sp_we, sp_ack, sp_fault;
    logic [31:0]  sp_addr;
    logic [127:0] sp_wdata, sp_rdata;

    excore_mmio dut_mmio (
        .clk_i(clk), .rst_n_i(rst_n),
        .cpu_req_i(mmio_req), .cpu_we_i(mmio_we),
        .cpu_addr_i(mmio_addr), .cpu_wdata_i(mmio_wdata),
        .cpu_ack_o(mmio_ack), .cpu_rdata_o(mmio_rdata),
        .mb_trap_pending_i(mb_trap_pending), .mb_trap_code_i(mb_trap_code),
        .mb_pc_i(mb_pc), .mb_opcode_i(mb_opcode), .mb_arg_i(mb_arg),
        .mb_heap_ptr_i(mb_heap_ptr), .mb_entry_count_i(mb_entry_count),
        .mb_entries_i(mb_entries),
        .res_go_o(res_go), .res_code_o(res_code),
        .res_fatal_code_o(res_fatal_code),
        .res_pop_count_o(res_pop_count), .res_push_count_o(res_push_count),
        .res_heap_ptr_o(res_heap_ptr), .res_entries_o(res_entries),
        .sp_req_o(sp_req), .sp_we_o(sp_we), .sp_addr_o(sp_addr),
        .sp_wdata_o(sp_wdata), .sp_ack_i(sp_ack), .sp_rdata_i(sp_rdata),
        .sp_fault_i(sp_fault)
    );

    pycore_mem_bank #(
        .DATA_WIDTH(DATA_W), .ADDR_WIDTH(32),
        .BLOCK_SHIFT(13), .BLOCK_COUNT(1), .READ_ONLY(0), .INIT_HEX("")
    ) mem_bank (
        .clk_i(clk), .rst_n_i(rst_n),
        .req_i(sp_req), .we_i(sp_we), .addr_i(sp_addr), .wdata_i(sp_wdata),
        .ack_o(sp_ack), .rdata_o(sp_rdata), .fault_o(sp_fault)
    );

    always #5 clk = ~clk;

    function automatic logic [127:0] peek_slot(input logic [31:0] addr);
        peek_slot = mem_bank.gen_block[0].blk.mem[addr[12:4]];
    endfunction

    task automatic clear_region(input logic [31:0] base, input int bytes);
        int off;
        for (off = 0; off < bytes; off += 16)
            mem_bank.gen_block[0].blk.mem[(base + off) >> 4] = 128'd0;
    endtask

    task automatic check(input bit condition, input string message);
        if (!condition) begin
            $error("[FAIL] %s", message);
            $finish;
        end
    endtask

    task automatic do_reset();
        rst_n = 1'b0;
        mb_trap_pending = 1'b0;
        mb_trap_code = 4'h0;
        mb_pc = 32'h0; mb_opcode = 8'h0; mb_arg = 32'h0;
        mb_heap_ptr = 32'h0; mb_entry_count = 3'h0;
        mb_entries[0] = 132'h0; mb_entries[1] = 132'h0; mb_entries[2] = 132'h0;
        clear_region(32'h0200, 32'h1E00);
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    endtask

    task automatic kick(input logic [31:0] heap_ptr, input int max_cycles);
        int i;
        mb_heap_ptr = heap_ptr;
        mb_trap_code = 4'd9; // ignored by harness; any pending bit starts it
        mb_entry_count = 3'd0;
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
        $error("[FAIL] timed out waiting for RES_GO");
        $finish;
    endtask

    initial begin
        logic [127:0] st, p0, p1, ru, om;
        clk = 1'b0;
        do_reset();
        kick(32'h0500, 200000);

        check(res_code == 4'd0, "expected RES_COMPLETED");
        check(!cpu_fault, "cpu fault");
        st = peek_slot(32'h0400);
        p0 = peek_slot(32'h0410);
        p1 = peek_slot(32'h0420);
        ru = peek_slot(32'h0430);
        om = peek_slot(32'h0440);
        $display("OUT_STATUS=%0d PTR0=0x%0h PTR1=0x%0h REUSE=0x%0h OOM=%0d",
                 st[31:0], p0[31:0], p1[31:0], ru[31:0], om[31:0]);
        check(st[31:0] == 32'd0, "harness reported failure status");
        check(p0[31:0] != 32'd0, "ptr0 nonzero");
        check(p1[31:0] != 32'd0, "ptr1 nonzero");
        check(p0[31:0] != p1[31:0], "two allocs distinct");
        check(ru[31:0] == p0[31:0], "free+alloc reused ptr0");
        check(om[31:0] != 32'd0, "OOM status nonzero");
        $display("PASS: tb_mm — alloc/free/reuse/OOM");
        $finish;
    end
endmodule
