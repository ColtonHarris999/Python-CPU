`include "pycore_defs.svh"

// Directed unit test for the RF ring: wrap-around init, occupancy full/empty,
// and push/pop faults. The production core ties push/pop to 0 and owns TOS
// itself; this bench drives the unused ports to pin the occupancy contract.
module tb_regfile;
    localparam int RF_DEPTH = PYCORE_RF_DEPTH;
    localparam int ADDR_W = $clog2(RF_DEPTH);
    localparam int OCC_W = ADDR_W + 1;

    logic clk;
    logic rst_n;
    logic [ADDR_W-1:0] rs1_addr;
    logic [ADDR_W-1:0] rs2_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs2;
    logic rd_we;
    logic [ADDR_W-1:0] rd_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] rd;
    logic set_locals_base;
    logic [ADDR_W-1:0] new_locals_base;
    logic init_frame;
    logic [ADDR_W-1:0] init_from;
    logic [ADDR_W-1:0] init_until;
    logic push_stack;
    logic pop_stack;
    logic [ADDR_W-1:0] tos_ptr;
    logic [ADDR_W-1:0] locals_base;
    logic stack_fault;
    logic [OCC_W-1:0] resident;

    pycore_regfile #(
        .RF_DEPTH(RF_DEPTH)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .rs1_addr_i(rs1_addr),
        .rs2_addr_i(rs2_addr),
        .rs1_o(rs1),
        .rs2_o(rs2),
        .rd_we_i(rd_we),
        .rd_addr_i(rd_addr),
        .rd_i(rd),
        .set_locals_base_i(set_locals_base),
        .new_locals_base_i(new_locals_base),
        .init_frame_i(init_frame),
        .init_from_i(init_from),
        .init_until_i(init_until),
        .push_stack_i(push_stack),
        .pop_stack_i(pop_stack),
        .tos_ptr_o(tos_ptr),
        .locals_base_o(locals_base),
        .stack_fault_o(stack_fault),
        .resident_o(resident)
    );

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    task automatic tick;
        begin
            #5 clk = 1'b1;
            #5 clk = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        rs1_addr = '0;
        rs2_addr = '0;
        rd_we = 1'b0;
        rd_addr = '0;
        rd = '0;
        set_locals_base = 1'b0;
        new_locals_base = '0;
        init_frame = 1'b0;
        init_from = '0;
        init_until = '0;
        push_stack = 1'b0;
        pop_stack = 1'b0;

        tick();
        rst_n = 1'b1;
        tick();

        check(tos_ptr == '0, "reset TOS must be 0");
        check(resident == '0, "reset occupancy must be empty");
        check(locals_base == '0, "reset locals_base must be 0");
        check(!stack_fault, "reset must not fault");

        // Wrap-around write/read: index 255 and 0 are distinct slots.
        rd_we = 1'b1;
        rd_addr = ADDR_W'(255);
        rd = {PY_TAG_INT, 128'd255};
        tick();
        rd_addr = ADDR_W'(0);
        rd = {PY_TAG_INT, 128'd1};
        tick();
        rd_addr = ADDR_W'(6);
        rd = {PY_TAG_INT, 128'd6};
        tick();
        rd_we = 1'b0;
        rs1_addr = ADDR_W'(255);
        rs2_addr = ADDR_W'(0);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_INT && pycore_get_val(rs1) == 128'd255,
              "RF[255] must hold the wrapped write");
        check(pycore_get_tag(rs2) == PY_TAG_INT && pycore_get_val(rs2) == 128'd1,
              "RF[0] must hold the index-0 write");

        // Init wrapping: locals_base=250, clear 12 slots → 250..255 and 0..5.
        new_locals_base = ADDR_W'(250);
        set_locals_base = 1'b1;
        init_frame = 1'b1;
        init_from = '0;
        init_until = ADDR_W'(12);
        tick();
        set_locals_base = 1'b0;
        init_frame = 1'b0;
        check(locals_base == ADDR_W'(250), "locals_base must wrap-install at 250");

        rs1_addr = ADDR_W'(250);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_UNINIT, "RF[250] must be UNINIT after wrap init");
        rs1_addr = ADDR_W'(255);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_UNINIT, "RF[255] must be UNINIT after wrap init");
        rs1_addr = ADDR_W'(0);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_UNINIT, "RF[0] must be UNINIT after wrap init");
        rs1_addr = ADDR_W'(5);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_UNINIT, "RF[5] must be UNINIT after wrap init");
        rs1_addr = ADDR_W'(6);
        tick();
        check(pycore_get_tag(rs1) == PY_TAG_INT && pycore_get_val(rs1) == 128'd6,
              "RF[6] must survive wrap init (outside [250, 250+12))");

        // Occupancy: 256 pushes fill the ring; the next push faults.
        rst_n = 1'b0;
        tick();
        rst_n = 1'b1;
        tick();
        push_stack = 1'b1;
        repeat (RF_DEPTH) tick();
        push_stack = 1'b0;
        tick();
        check(resident == OCC_W'(RF_DEPTH), "256 pushes must report full occupancy");
        check(tos_ptr == '0, "full occupancy wraps TOS back to 0 (empty/full disambiguation)");
        check(!stack_fault, "filling to RF_DEPTH must not fault");
        push_stack = 1'b1;
        tick();
        check(stack_fault, "push on full occupancy must fault");
        check(resident == OCC_W'(RF_DEPTH), "faulting push must not change occupancy");
        push_stack = 1'b0;
        tick();

        // Underflow: drain, then one extra pop.
        pop_stack = 1'b1;
        repeat (RF_DEPTH) tick();
        pop_stack = 1'b0;
        tick();
        check(resident == '0, "256 pops must report empty");
        check(tos_ptr == '0, "empty TOS is 0");
        check(!stack_fault, "draining to empty must not fault");
        pop_stack = 1'b1;
        tick();
        check(stack_fault, "pop on empty occupancy must fault");
        check(resident == '0, "faulting pop must not change occupancy");
        pop_stack = 1'b0;

        $display("PASS: tb_regfile — wrap init, full/empty occupancy, push/pop faults");
        $finish;
    end
endmodule
