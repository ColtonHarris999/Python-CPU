`include "pycore_defs.svh"

/* verilator lint_off UNUSEDSIGNAL */
// tb_frame: unit test for the simple push/pop call-frame manager.
//
// push_ack and pop_ack are tied to 1'b1 so every dmem transaction is
// acknowledged immediately (no real DRAM backing needed for these metadata
// tests).  pop_data is driven by a small "mock stack" that mirrors the
// two 128-bit slots pushed per frame, providing correct pc_return / tos /
// locals / cur_code restoration for the return-path checks.
module tb_frame;
    localparam int RF_DEPTH           = 12;
    localparam int RF_BASE            = 8;
    localparam int MAX_CALL_DEPTH     = 6;
    localparam int FRAME_ENTRY_BYTES  = 32;
    localparam int RF_AW              = $clog2(RF_DEPTH);

    logic clk;
    logic rst_n;
    logic call_valid;
    logic return_valid;
    logic [31:0]   pc_return_in;
    logic [RF_AW-1:0] tos_base_in;
    logic [RF_AW-1:0] locals_base_in;
    logic [RF_AW-1:0] new_locals_base_in;
    logic [31:0]   cur_code_in;
    logic [31:0]   pc_return_out;
    logic [RF_AW-1:0] tos_base_out;
    logic [RF_AW-1:0] locals_base_out;
    logic [31:0]   cur_code_out;
    logic [RF_AW-1:0] next_locals_base;
    logic          init_new_frame;
    logic          return_done;
    logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out;
    logic [31:0]   head_ptr_out;
    logic [31:0]   tail_ptr_out;
    logic          frame_fault;
    logic          frame_busy;
    // Push handshake — instant ack.
    logic          push_req;
    logic [31:0]   push_addr;
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] push_data;
    // Pop handshake — instant ack; data from mock stack.
    logic          pop_req;
    logic [31:0]   pop_addr;
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] pop_data_drv;

    pycore_frame #(
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH),
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE),
        .FRAME_ENTRY_BYTES(FRAME_ENTRY_BYTES)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .call_valid_i(call_valid),
        .return_valid_i(return_valid),
        .pc_return_in_i(pc_return_in),
        .tos_base_in_i(tos_base_in),
        .locals_base_in_i(locals_base_in),
        .cur_code_in_i(cur_code_in),
        .new_locals_base_in_i(new_locals_base_in),
        .pc_return_out_o(pc_return_out),
        .tos_base_out_o(tos_base_out),
        .locals_base_out_o(locals_base_out),
        .cur_code_out_o(cur_code_out),
        .next_locals_base_o(next_locals_base),
        .init_new_frame_o(init_new_frame),
        .return_done_o(return_done),
        .active_frames_out_o(active_frames_out),
        .head_ptr_out_o(head_ptr_out),
        .tail_ptr_out_o(tail_ptr_out),
        .frame_fault_o(frame_fault),
        .frame_busy_o(frame_busy),
        .push_req_o(push_req),
        .push_addr_o(push_addr),
        .push_data_o(push_data),
        .push_ack_i(1'b1),      // instant ack — no real DRAM
        .pop_req_o(pop_req),
        .pop_addr_o(pop_addr),
        .pop_data_i(pop_data_drv),
        .pop_ack_i(1'b1)        // instant ack — no real DRAM
    );

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Tiny mock stack: mirrors whatever was pushed so that pop restores the
    // correct values.  The DUT writes push_data on push_req; the mock stack
    // stores it and presents it via pop_data_drv on pop_req.
    // -----------------------------------------------------------------------
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] mock_stack [0:(MAX_CALL_DEPTH*2)-1];
    int mock_sp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mock_sp <= 0;
        end else begin
            if (push_req) begin
                mock_stack[mock_sp] <= push_data;
                mock_sp <= mock_sp + 1;
            end
            if (pop_req && mock_sp > 0) begin
                mock_sp <= mock_sp - 1;
            end
        end
    end

    // pop_data_drv is combinational: show the top-of-stack data while popping.
    assign pop_data_drv = (pop_req && mock_sp > 0) ?
                          mock_stack[mock_sp - 1] : '0;

    // -----------------------------------------------------------------------
    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    // do_call: pulse call_valid for one posedge then wait for init_new_frame.
    // With push_ack tied to 1, the push completes 2 cycles after call_valid.
    localparam int CALL_TIMEOUT = MAX_CALL_DEPTH * 2 + 4;
    task automatic do_call(
        input int pc_ret,
        input int tos,
        input int locals,
        input bit expect_fault
    );
        int wait_cycles;
        begin
            @(negedge clk);
            call_valid     = 1'b1;
            return_valid   = 1'b0;
            pc_return_in   = pc_ret[31:0];
            tos_base_in    = tos[RF_AW-1:0];
            locals_base_in = locals[RF_AW-1:0];
            cur_code_in    = 32'hC0DE_0000 ^ pc_ret[31:0];
            @(posedge clk);
            @(negedge clk);
            call_valid = 1'b0;

            wait_cycles = 0;
            while (!init_new_frame && !frame_fault) begin
                if (wait_cycles >= CALL_TIMEOUT) begin
                    $error("do_call timeout");
                    $finish;
                end
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
            end
            check(frame_fault == expect_fault, "call fault expectation mismatch");
            check(init_new_frame == !expect_fault, "call acceptance pulse mismatch");
        end
    endtask

    // do_return: pulse return_valid for one posedge then wait for return_done.
    localparam int RETURN_TIMEOUT = 8;
    task automatic do_return(input bit expect_fault);
        int wait_cycles;
        begin
            @(negedge clk);
            call_valid    = 1'b0;
            return_valid  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            return_valid  = 1'b0;

            wait_cycles = 0;
            while (!return_done && !frame_fault) begin
                if (wait_cycles >= RETURN_TIMEOUT) begin
                    $error("do_return timeout");
                    $finish;
                end
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
            end
            check(frame_fault == expect_fault, "return fault expectation mismatch");
            check(!init_new_frame, "return should not assert init_new_frame");
        end
    endtask

    initial begin
        clk              = 1'b0;
        rst_n            = 1'b0;
        call_valid       = 1'b0;
        return_valid     = 1'b0;
        pc_return_in     = '0;
        tos_base_in      = '0;
        locals_base_in   = '0;
        new_locals_base_in = '0;
        cur_code_in      = '0;

        #20;
        rst_n = 1'b1;
        @(posedge clk);

        // ------------------------------------------------------------------
        // Basic push/pop round-trip.
        // ------------------------------------------------------------------

        // Frame 0: call with pc=0x100, tos=2, locals=0.
        do_call(32'h100, 2, 0, 1'b0);
        check(active_frames_out == 1,
              "depth should be 1 after first call");
        check(head_ptr_out != 0,
              "head pointer should be non-zero after first call");

        // Frame 1: call with pc=0x200, tos=3, locals=0.
        do_call(32'h200, 3, 0, 1'b0);
        check(active_frames_out == 2,
              "depth should be 2 after second call");

        // Frame 2: call with pc=0x300, tos=4, locals=1.
        do_call(32'h300, 4, 1, 1'b0);
        check(active_frames_out == 3,
              "depth should be 3 after third call");

        // Return from frame 2 → should restore frame 1's context.
        do_return(1'b0);
        check(active_frames_out == 2, "depth should drop to 2 after return");
        check(pc_return_out == 32'h300,
              "pc_return_out should be 0x300 after popping frame 2");
        check(tos_base_out == RF_AW'(4),
              "tos_base_out should be 4 after popping frame 2");
        check(locals_base_out == RF_AW'(1),
              "locals_base_out should be 1 after popping frame 2");
        check(cur_code_out == (32'hC0DE_0000 ^ 32'h300),
              "cur_code_out mismatch for frame 2");

        // Return from frame 1.
        do_return(1'b0);
        check(active_frames_out == 1, "depth should drop to 1");
        check(pc_return_out == 32'h200, "pc_return_out mismatch for frame 1");
        check(cur_code_out == (32'hC0DE_0000 ^ 32'h200),
              "cur_code_out mismatch for frame 1");

        // Return from frame 0.
        do_return(1'b0);
        check(active_frames_out == 0, "all frames should be released");
        check(pc_return_out == 32'h100, "pc_return_out mismatch for frame 0");
        check(cur_code_out == (32'hC0DE_0000 ^ 32'h100),
              "cur_code_out mismatch for frame 0");
        check(head_ptr_out == 0, "head pointer should be 0 when stack is empty");

        // ------------------------------------------------------------------
        // Fault: return underflow.
        // ------------------------------------------------------------------
        do_return(1'b1);

        // ------------------------------------------------------------------
        // Fault: simultaneous call + return.
        // ------------------------------------------------------------------
        @(negedge clk);
        call_valid   = 1'b1;
        return_valid = 1'b1;
        pc_return_in = 32'h500;
        @(posedge clk);
        #1;
        check(frame_fault, "simultaneous call/return should fault");
        check(!init_new_frame, "simultaneous call/return must not accept frame");
        @(negedge clk);
        call_valid   = 1'b0;
        return_valid = 1'b0;

        // ------------------------------------------------------------------
        // Fault: depth overflow (fill to MAX_CALL_DEPTH then one more).
        // ------------------------------------------------------------------
        repeat (MAX_CALL_DEPTH) begin
            do_call(32'h600, 0, 0, 1'b0);
        end
        check(active_frames_out == MAX_CALL_DEPTH, "depth should equal MAX_CALL_DEPTH");
        do_call(32'h601, 0, 0, 1'b1);

        // Unwind.
        repeat (MAX_CALL_DEPTH) begin
            do_return(1'b0);
        end
        check(active_frames_out == 0, "stack should be fully unwound");

        $display("PASS: pycore_frame push/pop call-stack test complete");
        $finish;
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
