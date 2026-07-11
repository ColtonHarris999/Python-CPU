`include "pycore_defs.svh"

// Parameterized testbench for multi-function call tests.
// Loads PROG_HEX, runs until base-frame RETURN_VALUE retires, and checks
// the return entry against {EXPECTED_TAG, EXPECTED_VALUE}.
module tb_multifn #(
    parameter string PROG_HEX       = "pycore/programs/multifn_simple.hex",
    parameter string STRING_HEX     = "pycore/programs/string_mem.hex",
    parameter int    MAX_CYCLES     = 4000,
    parameter logic [3:0]                      EXPECTED_TAG   = PY_TAG_INT,
    parameter logic [PYCORE_VAL_WIDTH-1:0]     EXPECTED_VALUE = 128'd42
);
    localparam logic [2:0] CORE_S_WB = 3'd4;

    logic clk;
    logic rst_n;
    logic trap_out;
    logic [3:0]  trap_code;
    logic [63:0] cycle_count;
    logic dbg_wb_we;
    logic [6:0]  dbg_wb_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry;

    pycore_system #(
        .PROG_HEX  (PROG_HEX),
        .STRING_HEX(STRING_HEX)
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

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("[FAIL] %s", message);
                $finish;
            end
        end
    endtask

    initial begin
        int i;
        bit return_seen;
        logic [PYCORE_ENTRY_WIDTH-1:0] return_entry;
        logic [3:0]                    got_tag;
        logic [PYCORE_VAL_WIDTH-1:0]   got_val;

        clk = 1'b0;
        rst_n = 1'b0;
        return_seen = 0;

        #20;
        rst_n = 1'b1;

        for (i = 0; i < MAX_CYCLES; i++) begin
            @(posedge clk);

            if (trap_out) begin
                $error("[FAIL] program trapped (code=%0d) at cycle %0d",
                       trap_code, cycle_count);
                $finish;
            end

            // Detect base-frame RETURN_VALUE: no active frames and opcode matches.
            if ((dut.core.state_r == CORE_S_WB) &&
                (dut.core.cur_opcode_r == PY_OP_RETURN_VALUE) &&
                (dut.core.frame_active_depth == 0)) begin
                return_seen  = 1;
                return_entry = dut.core.rs1_r;
                break;
            end
        end

        check(return_seen,
              $sformatf("program did not complete within MAX_CYCLES=%0d", MAX_CYCLES));

        got_tag = pycore_get_tag(return_entry);
        got_val = pycore_get_val(return_entry);

        check(got_tag == EXPECTED_TAG,
              $sformatf("tag mismatch: expected %0d, got %0d", EXPECTED_TAG, got_tag));
        check(got_val == EXPECTED_VALUE,
              $sformatf("value mismatch: expected 0x%0h, got 0x%0h",
                        EXPECTED_VALUE, got_val));

        $display("PASS: %s — tag=%0d value=0x%0h cycles=%0d",
                 PROG_HEX, got_tag, got_val[63:0], cycle_count);
        $finish;
    end
endmodule
