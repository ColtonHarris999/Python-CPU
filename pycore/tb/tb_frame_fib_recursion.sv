`include "pycore_defs.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
module tb_frame_fib_recursion;
    localparam int RF_DEPTH = 16;
    localparam int RF_BASE = 12;                // resident RF window = 4 entries
    localparam int MAX_CALL_DEPTH = 64;
    localparam int FRAME_MAX_SLOTS = 8;
    localparam int FIB_N = 11;                  // depth 12, total calls 287

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
    // New spill-handshake ports — spill_ack is tied to 1 for instant ack.
    logic                        frame_busy;
    logic                        spill_req;
    logic [$clog2(RF_DEPTH)-1:0] spill_rf_idx_out;
    logic [31:0]                 spill_addr_out;

    int max_active_frames;
    int max_spill_slots;
    int call_count;
    int return_count;

    pycore_frame #(
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH),
        .FRAME_MAX_SLOTS(FRAME_MAX_SLOTS),
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE)
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

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (active_frames_out > max_active_frames) begin
                max_active_frames <= active_frames_out;
            end
            if (dut.spill_used_count_q > max_spill_slots) begin
                max_spill_slots <= dut.spill_used_count_q;
            end
        end
    end

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    task automatic do_call(input int pc_seed);
        localparam int CALL_TIMEOUT = FRAME_MAX_SLOTS * 2 + 8;
        int wait_cycles;
        begin
            @(negedge clk);
            call_valid     = 1'b1;
            return_valid   = 1'b0;
            frame_slots_in = 2;
            pc_return_in   = 32'(pc_seed);
            tos_base_in    = '0;
            locals_base_in = '0;

            // Latch call_valid for one posedge, then clear.
            @(posedge clk);
            @(negedge clk);
            call_valid = 1'b0;

            wait_cycles = 0;
            while (!init_new_frame && !frame_fault) begin
                if (wait_cycles >= CALL_TIMEOUT) begin
                    $error("do_call timeout: frame module did not respond");
                    $finish;
                end
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
            end
            check(!frame_fault, "recursive call should not frame-fault");
            check(init_new_frame, "call should initialize a new frame");
            call_count = call_count + 1;
        end
    endtask

    task automatic do_return();
        begin
            @(negedge clk);
            call_valid = 1'b0;
            return_valid = 1'b1;
            @(posedge clk);
            #1;
            check(!frame_fault, "return should not frame-fault");
            check(!init_new_frame, "return must not initialize frame");
            return_count = return_count + 1;
            @(negedge clk);
            return_valid = 1'b0;
        end
    endtask

    task automatic fib_walk(input int n);
        begin
            do_call(n);
            if (n > 1) begin
                fib_walk(n - 1);
                fib_walk(n - 2);
            end
            do_return();
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
        return_value_in = pycore_int_entry(64'd0);
        max_active_frames = 0;
        max_spill_slots = 0;
        call_count = 0;
        return_count = 0;

        #20;
        rst_n = 1'b1;
        @(posedge clk);

        fib_walk(FIB_N);

        check(call_count == return_count, "all recursive calls must return");
        check(active_frames_out == 0, "frame stack must fully unwind");
        check(!frame_fault, "frame fault must remain clear after full recursion");
        check(max_active_frames > (RF_DEPTH - RF_BASE),
              "recursion depth should exceed resident RF stack window");
        check(max_spill_slots > 0, "deep recursion should spill frame data");
        check(call_count > 200, "test should exercise a high recursion call count");

        $display("PASS: recursive Fibonacci frame stress complete (calls=%0d max_depth=%0d max_spill=%0d)",
                 call_count, max_active_frames, max_spill_slots);
        $finish;
    end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on UNUSEDSIGNAL */
