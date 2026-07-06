`include "pycore_defs.svh"

/* verilator lint_off UNUSEDSIGNAL */
// tb_frame_fib_recursion: stress-test the simple push/pop frame manager by
// simulating the full Fibonacci call tree for fib(FIB_N).
//
// fib(11) generates 287 calls and a maximum recursion depth of 11.
// With push_ack/pop_ack tied to 1, every DRAM transaction completes in one
// extra cycle (instant mock ack).  A mock stack mirrors pushed data for
// correct restoration on pop.
module tb_frame_fib_recursion;
    localparam int RF_DEPTH          = 16;
    localparam int RF_BASE           = 12;
    localparam int MAX_CALL_DEPTH    = 64;
    localparam int FRAME_ENTRY_BYTES = 16;
    localparam int FIB_N             = 11;
    localparam int RF_AW             = $clog2(RF_DEPTH);

    logic clk;
    logic rst_n;
    logic call_valid;
    logic return_valid;
    logic [31:0]      pc_return_in;
    logic [RF_AW-1:0] tos_base_in;
    logic [RF_AW-1:0] locals_base_in;
    logic [RF_AW-1:0] new_locals_base_in;
    logic [31:0]      pc_return_out;
    logic [RF_AW-1:0] tos_base_out;
    logic [RF_AW-1:0] locals_base_out;
    logic [RF_AW-1:0] next_locals_base;
    logic             init_new_frame;
    logic             return_done;
    logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out;
    logic [31:0]      head_ptr_out;
    logic [31:0]      tail_ptr_out;
    logic             frame_fault;
    logic             frame_busy;
    logic             push_req;
    logic [31:0]      push_addr;
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] push_data;
    logic             pop_req;
    logic [31:0]      pop_addr;
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] pop_data_drv;

    int max_active_frames;
    int call_count;
    int return_count;

    pycore_frame #(
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH),
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE),
        .FRAME_ENTRY_BYTES(FRAME_ENTRY_BYTES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .call_valid(call_valid),
        .return_valid(return_valid),
        .pc_return_in(pc_return_in),
        .tos_base_in(tos_base_in),
        .locals_base_in(locals_base_in),
        .new_locals_base_in(new_locals_base_in),
        .pc_return_out(pc_return_out),
        .tos_base_out(tos_base_out),
        .locals_base_out(locals_base_out),
        .next_locals_base(next_locals_base),
        .init_new_frame(init_new_frame),
        .return_done(return_done),
        .active_frames_out(active_frames_out),
        .head_ptr_out(head_ptr_out),
        .tail_ptr_out(tail_ptr_out),
        .frame_fault(frame_fault),
        .frame_busy(frame_busy),
        .push_req(push_req),
        .push_addr(push_addr),
        .push_data(push_data),
        .push_ack(1'b1),
        .pop_req(pop_req),
        .pop_addr(pop_addr),
        .pop_data(pop_data_drv),
        .pop_ack(1'b1)
    );

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Mock stack (same scheme as tb_frame).
    // -----------------------------------------------------------------------
    logic [PYCORE_DMEM_DATA_WIDTH-1:0] mock_stack [0:MAX_CALL_DEPTH-1];
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

    assign pop_data_drv = (pop_req && mock_sp > 0) ?
                          mock_stack[mock_sp - 1] : '0;

    // Track peak depth.
    always_ff @(posedge clk) begin
        if (rst_n && active_frames_out > max_active_frames) begin
            max_active_frames <= active_frames_out;
        end
    end

    // -----------------------------------------------------------------------
    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    localparam int CALL_TIMEOUT   = 8;
    localparam int RETURN_TIMEOUT = 8;

    task automatic do_call(input int pc_seed);
        int wait_cycles;
        begin
            @(negedge clk);
            call_valid     = 1'b1;
            return_valid   = 1'b0;
            pc_return_in   = 32'(pc_seed);
            tos_base_in    = '0;
            locals_base_in = '0;
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
            check(!frame_fault, "recursive call should not frame-fault");
            check(init_new_frame, "call should initialize a new frame");
            call_count = call_count + 1;
        end
    endtask

    task automatic do_return();
        int wait_cycles;
        begin
            @(negedge clk);
            call_valid   = 1'b0;
            return_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            return_valid = 1'b0;

            wait_cycles = 0;
            while (!return_done && !frame_fault) begin
                if (wait_cycles >= RETURN_TIMEOUT) begin
                    $error("do_return timeout");
                    $finish;
                end
                wait_cycles = wait_cycles + 1;
                @(posedge clk);
            end
            check(!frame_fault, "return should not frame-fault");
            check(!init_new_frame, "return must not initialize frame");
            return_count = return_count + 1;
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
        clk                = 1'b0;
        rst_n              = 1'b0;
        call_valid         = 1'b0;
        return_valid       = 1'b0;
        pc_return_in       = '0;
        tos_base_in        = '0;
        locals_base_in     = '0;
        new_locals_base_in = '0;
        max_active_frames  = 0;
        call_count         = 0;
        return_count       = 0;

        #20;
        rst_n = 1'b1;
        @(posedge clk);

        fib_walk(FIB_N);

        check(call_count == return_count, "all recursive calls must return");
        check(active_frames_out == 0, "frame stack must fully unwind");
        check(!frame_fault, "frame fault must remain clear after full recursion");
        check(max_active_frames > 1,
              "recursion should exercise multiple stack frames");
        check(call_count > 200, "test should exercise a high recursion call count");

        $display("PASS: recursive Fibonacci frame stress complete (calls=%0d max_depth=%0d)",
                 call_count, max_active_frames);
        $finish;
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
