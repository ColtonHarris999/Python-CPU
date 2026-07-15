`include "pycore_defs.svh"

// End-to-end pipeline + memory test. Drives pycore_system (CPU + tiled imem +
// tiled dmem + const ROM), loads a hand-written program image into imem, and
// verifies a full IF/ID/EX/MEM/WB run:
//   - >=3 opcodes fetched from imem and retired through writeback
//   - LOAD_CONST result reaches the register file via MEM -> WB
//   - STORE_FAST -> LOAD_FAST forwarding propagates a tagged value
//   - a PTR dmem store followed by a PTR dmem load round-trips through MEM
module tb_pycore;
    logic clk;
    logic rst_n;
    logic trap_out;
    logic [3:0] trap_code;
    logic [63:0] cycle_count;
    logic dbg_wb_we;
    logic [7:0] dbg_wb_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry;

    pycore_system #(
        .PROG_HEX("pycore/programs/mem_demo_prog.hex")
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .trap_out_o(trap_out),
        .trap_code_o(trap_code),
        .cycle_count_o(cycle_count),
        .dbg_wb_we_o(dbg_wb_we),
        .dbg_wb_addr_o(dbg_wb_addr),
        .dbg_wb_entry_o(dbg_wb_entry)
    );

    always #5 clk = ~clk;

    // Shadow register file rebuilt by snooping the writeback port.
    logic [PYCORE_ENTRY_WIDTH-1:0] shadow [0:255];
    int wb_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_count <= 0;
        end else if (dbg_wb_we) begin
            shadow[dbg_wb_addr] <= dbg_wb_entry;
            wb_count <= wb_count + 1;
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

    logic [PYCORE_ENTRY_WIDTH-1:0] exp_const;
    logic [PYCORE_ENTRY_WIDTH-1:0] exp_load;

    initial begin
        int i;
        clk = 1'b0;
        rst_n = 1'b0;
        for (i = 0; i < 96; i++) begin
            shadow[i] = pycore_make_entry(PY_TAG_UNINIT, '0);
        end
        #20;
        rst_n = 1'b1;

        repeat (160) @(posedge clk);

        exp_const = pycore_int_entry(64'h0000_0000_dead_beef);
        exp_load  = pycore_int_entry(64'd171);

        check(!trap_out, "pipeline should not trap on the memory demo program");
        check(cycle_count != 64'b0, "cycle counter did not advance");
        check(wb_count >= 3, "fewer than 3 opcodes retired through writeback");

        // LOAD_CONST -> STORE_FAST: constant reached RF through MEM -> WB.
        check(pycore_get_tag(shadow[1]) == PY_TAG_INT, "local 1 should be INT");
        check(shadow[1] == exp_const, "LOAD_CONST value did not reach RF via MEM/WB");

        // STORE_FAST -> LOAD_FAST forwarding produced the same tagged value.
        check(shadow[2] == exp_const,
              "STORE_FAST->LOAD_FAST forwarding failed (stale RF read)");

        // PTR dmem store then load round-tripped through the MEM stage.
        check(pycore_get_tag(shadow[32]) == PY_TAG_INT, "loaded PTR value should be INT");
        check(shadow[32] == exp_load,
              "PTR dmem store/load did not round-trip through MEM stage");

        $display("PASS: pycore_system pipeline + memory end-to-end test complete (wb_count=%0d, cycles=%0d)",
                 wb_count, cycle_count);
        $finish;
    end
endmodule
