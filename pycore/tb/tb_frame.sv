`include "pycore_defs.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
module tb_frame;
    localparam int RF_DEPTH = 12;
    localparam int RF_BASE = 8;
    localparam int MAX_CALL_DEPTH = 6;
    localparam int FRAME_MAX_SLOTS = 6;
    localparam int FRAME_NODE_BYTES = 64;
    localparam logic [31:0] STACK_BASE_ADDR = 32'h0001_0000;
    localparam int STACK_SIZE_BYTES = 512;
    localparam logic [31:0] SPILL_BASE_ADDR = 32'h0002_0000;
    localparam int SPILL_SIZE_BYTES = 256;
    localparam int SPILL_SLOT_BYTES = 16;

    logic clk;
    logic rst_n;
    logic call_valid;
    logic return_valid;
    logic [31:0] pc_return_in;
    logic [$clog2(RF_DEPTH)-1:0] tos_base_in;
    logic [$clog2(RF_DEPTH)-1:0] locals_base_in;
    logic [$clog2(RF_DEPTH)-1:0] new_locals_base_in;
    logic [$clog2(FRAME_MAX_SLOTS+1)-1:0] frame_slots_in;
    logic [PYCORE_ENTRY_WIDTH-1:0] return_value_in;
    logic [31:0] pc_return_out;
    logic [$clog2(RF_DEPTH)-1:0] tos_base_out;
    logic [$clog2(RF_DEPTH)-1:0] locals_base_out;
    logic [$clog2(RF_DEPTH)-1:0] next_locals_base;
    logic init_new_frame;
    logic [PYCORE_ENTRY_WIDTH-1:0] return_value_out;
    logic [31:0] head_ptr_out;
    logic [31:0] tail_ptr_out;
    logic [31:0] alloc_ptr_out;
    logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out;
    logic [$clog2(RF_DEPTH-RF_BASE+1)-1:0] resident_regs_out;
    logic frame_fault;
    // New spill-handshake ports.  spill_ack is tied to 1 so that the
    // frame module processes each spill in a single clock cycle, keeping
    // the testbench's per-call loop responsive without real dmem backing.
    logic                        frame_busy;
    logic                        spill_req;
    logic [$clog2(RF_DEPTH)-1:0] spill_rf_idx_out;
    logic [31:0]                 spill_addr_out;

    pycore_frame #(
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH),
        .FRAME_MAX_SLOTS(FRAME_MAX_SLOTS),
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE),
        .STACK_BASE_ADDR(STACK_BASE_ADDR),
        .STACK_SIZE_BYTES(STACK_SIZE_BYTES),
        .FRAME_NODE_BYTES(FRAME_NODE_BYTES),
        .SPILL_BASE_ADDR(SPILL_BASE_ADDR),
        .SPILL_SIZE_BYTES(SPILL_SIZE_BYTES),
        .SPILL_SLOT_BYTES(SPILL_SLOT_BYTES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .call_valid(call_valid),
        .return_valid(return_valid),
        .pc_return_in(pc_return_in),
        .tos_base_in(tos_base_in),
        .locals_base_in(locals_base_in),
        .new_locals_base_in(new_locals_base_in),
        .frame_slots_in(frame_slots_in),
        .return_value_in(return_value_in),
        .pc_return_out(pc_return_out),
        .tos_base_out(tos_base_out),
        .locals_base_out(locals_base_out),
        .next_locals_base(next_locals_base),
        .init_new_frame(init_new_frame),
        .return_value_out(return_value_out),
        .head_ptr_out(head_ptr_out),
        .tail_ptr_out(tail_ptr_out),
        .alloc_ptr_out(alloc_ptr_out),
        .active_frames_out(active_frames_out),
        .resident_regs_out(resident_regs_out),
        .frame_fault(frame_fault),
        .frame_busy(frame_busy),
        .spill_req(spill_req),
        .spill_rf_idx_out(spill_rf_idx_out),
        .spill_addr_out(spill_addr_out),
        .spill_ack(1'b1)   // instant ack — no real dmem backing in this TB
    );

    always #5 clk = ~clk;

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    task automatic do_call(
        input int slots,
        input int pc_ret,
        input int tos,
        input int locals,
        input bit expect_fault
    );
        // Maximum wait: FRAME_MAX_SLOTS slots * 2 cycles each (alloc + possible
        // spill) + a small margin.  With spill_ack tied high each spill ack
        // takes one extra cycle.
        localparam int CALL_TIMEOUT = FRAME_MAX_SLOTS * 2 + 8;
        int wait_cycles;
        begin
            // Drive inputs on the negedge, then allow the frame module to
            // sample call_valid on the following posedge.
            @(negedge clk);
            call_valid     = 1'b1;
            return_valid   = 1'b0;
            frame_slots_in = slots[$clog2(FRAME_MAX_SLOTS+1)-1:0];
            pc_return_in   = pc_ret[31:0];
            tos_base_in    = tos[$clog2(RF_DEPTH)-1:0];
            locals_base_in = locals[$clog2(RF_DEPTH)-1:0];

            // Let the frame module latch call_valid on this posedge, then
            // immediately clear it so that when the module later returns to
            // FS_IDLE it does not mistake the still-high call_valid for a
            // second call.
            @(posedge clk);
            @(negedge clk);
            call_valid = 1'b0;

            // Wait for init_new_frame or frame_fault.  Latency is variable:
            // each evicted slot requires an extra FS_CALL_SPILL cycle.
            // Check is done synchronously at the posedge (no #1 delay) so
            // that the read sees the NBA values from the PREVIOUS posedge
            // rather than the NBA values being scheduled for the current
            // posedge which would clear init_new_frame_q back to 0.
            wait_cycles = 0;
            while (!init_new_frame && !frame_fault) begin
                if (wait_cycles >= CALL_TIMEOUT) begin
                    $error("do_call timeout: frame module did not respond");
                    $finish;
                end
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
            end
            check(frame_fault == expect_fault, "call fault expectation mismatch");
            check(init_new_frame == !expect_fault, "call acceptance pulse mismatch");
        end
    endtask

    task automatic do_return(input bit expect_fault);
        begin
            @(negedge clk);
            call_valid = 1'b0;
            return_valid = 1'b1;
            @(posedge clk);
            #1;
            check(frame_fault == expect_fault, "return fault expectation mismatch");
            check(!init_new_frame, "return should not assert init_new_frame");
            @(negedge clk);
            return_valid = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        call_valid = 1'b0;
        return_valid = 1'b0;
        pc_return_in = '0;
        tos_base_in = '0;
        locals_base_in = '0;
        new_locals_base_in = '0;
        frame_slots_in = '0;
        return_value_in = pycore_int_entry(64'h1234);

        #20;
        rst_n = 1'b1;
        @(posedge clk);

        // Frame 0: fits in RF with no spill.
        do_call(3, 32'h100, 8, 1, 1'b0);
        check(active_frames_out == 1, "frame depth should be 1 after first call");
        check(resident_regs_out == 3, "resident count should be 3 after first call");
        check(head_ptr_out == STACK_BASE_ADDR, "head pointer mismatch for first frame");
        check(tail_ptr_out == STACK_BASE_ADDR, "tail pointer mismatch for first frame");
        check(alloc_ptr_out == STACK_BASE_ADDR, "alloc pointer should point at frame 0");
        check(dut.slot_map_addr[0][0] == 32'b0, "frame0 slot0 should still be resident");
        check(dut.slot_map_addr[0][1] == 32'b0, "frame0 slot1 should still be resident");
        check(dut.slot_map_addr[0][2] == 32'b0, "frame0 slot2 should still be resident");

        // Frame 1: forces two spills from the oldest frame (frame 0).
        do_call(3, 32'h200, 9, 2, 1'b0);
        check(active_frames_out == 2, "frame depth should be 2 after second call");
        check(resident_regs_out == 4, "resident count should saturate to RF ring capacity");
        check(head_ptr_out == STACK_BASE_ADDR, "head pointer should stay at frame 0");
        check(tail_ptr_out == STACK_BASE_ADDR + FRAME_NODE_BYTES, "tail pointer should move to frame 1");
        check(dut.frame_spill_count[0] == 2, "frame0 should have two spilled slots");
        check(dut.frame_resident_count[0] == 1, "frame0 should retain one resident slot");
        check(dut.slot_map_addr[0][0] != 0, "frame0 slot0 should be spilled");
        check(dut.slot_map_addr[0][1] != 0, "frame0 slot1 should be spilled");
        check(dut.slot_map_addr[0][2] == 0, "frame0 slot2 should still be resident");
        check(alloc_ptr_out == STACK_BASE_ADDR, "alloc pointer should still point to frame 0");

        // Frame 2: spills one remaining slot from frame 0 and one from frame 1.
        do_call(2, 32'h300, 10, 3, 1'b0);
        check(active_frames_out == 3, "frame depth should be 3 after third call");
        check(resident_regs_out == 4, "resident count should remain ring capacity");
        check(dut.frame_spill_count[0] == 3, "frame0 should be fully spilled");
        check(dut.frame_resident_count[0] == 0, "frame0 should have no resident slots");
        check(dut.frame_spill_count[1] == 1, "frame1 should have one spilled slot");
        check(dut.frame_resident_count[1] == 2, "frame1 should retain two resident slots");
        check(dut.slot_map_addr[0][2] != 0, "frame0 slot2 should now be spilled");
        check(alloc_ptr_out == STACK_BASE_ADDR + FRAME_NODE_BYTES,
              "alloc pointer should move to frame 1");

        // Pop frame 2 and frame 1, verify linked-list tail movement and reclaim.
        do_return(1'b0);
        check(active_frames_out == 2, "frame depth should be 2 after returning frame2");
        check(resident_regs_out == 2, "frame2 resident regs should be reclaimed");
        check(tail_ptr_out == STACK_BASE_ADDR + FRAME_NODE_BYTES, "tail should point to frame1");
        check(dut.spill_used_count_q == 4, "spill slot count should still include frame0+frame1");

        do_return(1'b0);
        check(active_frames_out == 1, "frame depth should be 1 after returning frame1");
        check(resident_regs_out == 0, "all resident slots should be reclaimed");
        check(tail_ptr_out == STACK_BASE_ADDR, "tail should point back to frame0");
        check(alloc_ptr_out == 0, "alloc pointer should be null when no frame is resident");
        check(dut.spill_used_count_q == 3, "frame1 spill slot should have been released");

        // Reuse ring space after reclaim.
        do_call(4, 32'h400, 11, 4, 1'b0);
        check(active_frames_out == 2, "frame depth should be 2 after frame3 call");
        check(resident_regs_out == 4, "frame3 should occupy entire resident ring");
        check(dut.frame_spill_count[1] == 0, "new frame should begin without spills");
        check(alloc_ptr_out == STACK_BASE_ADDR + FRAME_NODE_BYTES,
              "alloc pointer should point to the only resident frame");

        // Drain all frames and validate complete reclaim.
        do_return(1'b0);
        do_return(1'b0);
        check(active_frames_out == 0, "all frames should be released");
        check(resident_regs_out == 0, "resident ring should be empty");
        check(head_ptr_out == 0, "head pointer should be null after full unwind");
        check(tail_ptr_out == 0, "tail pointer should be null after full unwind");
        check(dut.spill_used_count_q == 0, "all spill slots should be released");

        // Fault behavior: return underflow.
        do_return(1'b1);

        // Fault behavior: slots request beyond FRAME_MAX_SLOTS.
        do_call(FRAME_MAX_SLOTS + 1, 32'h500, 0, 0, 1'b1);

        // Fault behavior: depth overflow.
        repeat (MAX_CALL_DEPTH) begin
            do_call(0, 32'h600, 0, 0, 1'b0);
        end
        do_call(0, 32'h601, 0, 0, 1'b1);
        repeat (MAX_CALL_DEPTH) begin
            do_return(1'b0);
        end

        // Fault behavior: spill storage exhaustion.
        do_call(4, 32'h700, 0, 0, 1'b0); // fill ring
        do_call(6, 32'h701, 0, 0, 1'b0); // +6 spills
        do_call(6, 32'h702, 0, 0, 1'b0); // +6 spills
        do_call(6, 32'h703, 0, 0, 1'b1); // +6 spills => should exceed SPILL_SLOTS
        // unwind accepted frames
        while (active_frames_out > 0) begin
            do_return(1'b0);
        end

        // Fault behavior: call+return in same cycle.
        @(negedge clk);
        call_valid = 1'b1;
        return_valid = 1'b1;
        frame_slots_in = 2;
        @(posedge clk);
        #1;
        check(frame_fault, "simultaneous call/return should fault");
        check(!init_new_frame, "simultaneous call/return must not accept a frame");
        @(negedge clk);
        call_valid = 1'b0;
        return_valid = 1'b0;

        $display("PASS: pycore_frame ring-spill frame manager test complete");
        $finish;
    end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on UNUSEDSIGNAL */
