`include "pycore_defs.svh"

// Fetch line-buffer directed coverage (memory_system_plan.md P4b):
// one memory request per 64 B line, CACHE/EXTENDED_ARG fold inside the
// buffer, branch to the same line issues no request, CACHE_EN=0 (no
// line_valid) still fetches one slot per req. Architectural PC stays in
// wordcode units.
module tb_fetch;
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 64;
    localparam int LINE_BYTES = 64;
    localparam int SLOTS      = 8;

    logic clk, rst_n, stall, flush, branch_taken;
    logic [31:0] branch_target;
    logic req, we, ack, line_valid;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] wdata, rdata;
    logic [LINE_BYTES*8-1:0] line;
    logic instr_valid;
    logic [7:0]  opcode;
    logic [31:0] arg, pc;
    logic [31:0] mem_reqs, buf_hits;

    logic [DATA_WIDTH-1:0] slots [0:31];
    logic                  give_line;

    function automatic logic [DATA_WIDTH-1:0] mk_slot(
        input logic [7:0] op,
        input logic [31:0] a
    );
        mk_slot = {24'b0, a, op};
    endfunction

    function automatic logic [LINE_BYTES*8-1:0] pack_line(input int base);
        pack_line = {slots[base+7], slots[base+6], slots[base+5], slots[base+4],
                     slots[base+3], slots[base+2], slots[base+1], slots[base+0]};
    endfunction

    pycore_fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .stall_i(stall),
        .flush_i(flush),
        .branch_taken_i(branch_taken),
        .branch_target_i(branch_target),
        .imem_req_o(req),
        .imem_we_o(we),
        .imem_addr_o(addr),
        .imem_wdata_o(wdata),
        .imem_ack_i(ack),
        .imem_rdata_i(rdata),
        .imem_line_i(line),
        .imem_line_valid_i(line_valid),
        .instr_valid_o(instr_valid),
        .opcode_o(opcode),
        .arg_o(arg),
        .pc_o(pc),
        .mem_req_count_o(mem_reqs),
        .buf_hit_count_o(buf_hits)
    );

    always #5 clk = ~clk;

    // 1-cycle ack slave. Captures on req; drives rdata/line with ack.
    logic                   pend_r;
    logic [ADDR_WIDTH-1:0]  cap_addr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend_r     <= 1'b0;
            cap_addr_r <= '0;
            ack        <= 1'b0;
            rdata      <= '0;
            line       <= '0;
            line_valid <= 1'b0;
        end else begin
            ack        <= 1'b0;
            line_valid <= 1'b0;
            if (req && !pend_r) begin
                pend_r     <= 1'b1;
                cap_addr_r <= addr;
            end else if (pend_r) begin
                pend_r     <= 1'b0;
                ack        <= 1'b1;
                rdata      <= slots[cap_addr_r[ADDR_WIDTH-1:3]];
                line       <= pack_line(int'(cap_addr_r[ADDR_WIDTH-1:6] << 3));
                line_valid <= give_line;
            end
        end
    end

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    task automatic wait_instr();
        int n;
        n = 0;
        while (!instr_valid) begin
            @(negedge clk);
            n++;
            check(n < 64, "timeout waiting for instr_valid");
        end
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        stall = 1'b0;
        flush = 1'b0;
        branch_taken = 1'b0;
        branch_target = '0;
        give_line = 1'b1;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    initial begin
        int i;
        clk = 1'b0;
        for (i = 0; i < 32; i++)
            slots[i] = mk_slot(PY_OP_NOP, 32'(i));

        // --- eight NOPs in one line: one mem req, eight instr, PC 0..7
        reset_dut();
        for (i = 0; i < 8; i++) begin
            wait_instr();
            check(opcode == PY_OP_NOP, $sformatf("nop opcode slot %0d", i));
            check(pc == 32'(i), $sformatf("nop pc=%0d want %0d", pc, i));
            check(arg == 32'(i), $sformatf("nop arg slot %0d", i));
            @(negedge clk);
        end
        check(mem_reqs == 32'd1, $sformatf("8 nops should be 1 mem req, got %0d", mem_reqs));
        check(buf_hits != 0, "expected buffer hits after the fill");

        // --- CACHE, CACHE, NOP(arg=9), CACHE, NOP(arg=10): fold inside buffer
        slots[0] = mk_slot(PY_OP_CACHE, 0);
        slots[1] = mk_slot(PY_OP_CACHE, 0);
        slots[2] = mk_slot(PY_OP_NOP, 32'd9);
        slots[3] = mk_slot(PY_OP_CACHE, 0);
        slots[4] = mk_slot(PY_OP_NOP, 32'd10);
        slots[5] = mk_slot(PY_OP_NOP, 32'd11);
        slots[6] = mk_slot(PY_OP_NOP, 32'd12);
        slots[7] = mk_slot(PY_OP_NOP, 32'd13);
        reset_dut();
        wait_instr();
        check(opcode == PY_OP_NOP && pc == 32'd2 && arg == 32'd9,
              $sformatf("folded CACHE want pc=2 arg=9 got pc=%0d arg=%0d", pc, arg));
        @(negedge clk);
        wait_instr();
        check(opcode == PY_OP_NOP && pc == 32'd4 && arg == 32'd10,
              $sformatf("second nop want pc=4 got pc=%0d", pc));
        check(mem_reqs == 32'd1, $sformatf("CACHE fold should be 1 mem req, got %0d", mem_reqs));

        // --- EXTENDED_ARG then NOP: folded arg, PC of the real opcode
        slots[0] = mk_slot(PY_OP_EXTENDED_ARG, 32'h01);
        slots[1] = mk_slot(PY_OP_NOP, 32'h02);
        for (i = 2; i < 8; i++)
            slots[i] = mk_slot(PY_OP_NOP, 32'(i));
        reset_dut();
        wait_instr();
        check(opcode == PY_OP_NOP && pc == 32'd1 && arg == 32'h0102,
              $sformatf("EA fold want pc=1 arg=0x102 got pc=%0d arg=0x%0h", pc, arg));
        check(mem_reqs == 32'd1, "EA fold extra mem req");

        // --- branch back into the captured line: no extra request
        for (i = 0; i < 8; i++)
            slots[i] = mk_slot(PY_OP_NOP, 32'(i));
        reset_dut();
        wait_instr();
        check(pc == 32'd0, "first nop");
        @(negedge clk);
        wait_instr();
        check(pc == 32'd1, "second nop");
        @(negedge clk);
        branch_taken = 1'b1;
        branch_target = 32'd0;
        @(negedge clk);
        branch_taken = 1'b0;
        wait_instr();
        check(pc == 32'd0 && opcode == PY_OP_NOP, "branch to slot 0 of same line");
        check(mem_reqs == 32'd1, $sformatf("same-line branch extra req (%0d)", mem_reqs));

        // --- no line_valid: one request per slot (CACHE_EN=0 shape)
        reset_dut();
        give_line = 1'b0;
        for (i = 0; i < 4; i++) begin
            wait_instr();
            check(pc == 32'(i), $sformatf("bypass pc %0d", i));
            @(negedge clk);
        end
        check(mem_reqs == 32'd4, $sformatf("bypass should be 4 reqs, got %0d", mem_reqs));
        check(buf_hits == 32'd0, "bypass must not hit the line buffer");

        $display("PASS: pycore_fetch line buffer (fold/branch/bypass)");
        $finish;
    end
endmodule
