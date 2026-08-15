`include "pycore_defs.svh"

// Testbench for container (LIST/DICT/TUPLE) operations.
// Parameterized over PROG_HEX and the expected return tag+value.
// Runs until RETURN_VALUE (or EXPECT_TRAP) like other container/image TBs.
//
// When EXPECT_TRAP is set, the test PASSES iff trap_out fires with
// trap_code == EXPECTED_TRAP_CODE before MAX_CYCLES, and FAILS on a clean
// return. When EXPECT_TRAP == 0, any trap is a failure (legacy behavior).
module tb_container #(
    parameter string PROG_HEX       = "pycore/programs/list_build_index.hex",
    parameter string STRING_HEX     = "pycore/programs/string_mem.hex",
    parameter string DMEM_HEX       = "",
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE,
    parameter int    MAX_CYCLES     = 8000,
    parameter logic [3:0]                  EXPECTED_TAG   = PY_TAG_INT,
    parameter logic [PYCORE_VAL_WIDTH-1:0] EXPECTED_VALUE = 128'd99,
    parameter bit    EXPECT_TRAP         = 1'b0,
    parameter logic [4:0] EXPECTED_TRAP_CODE = PY_TRAP_MEM_FAULT,
    // BOOT_EN passes through to pycore_system.  Legacy hand-assembled
    // container fixtures use BOOT_EN=0 (no image-boot walk); real image
    // programs built by image_from_source.py use BOOT_EN=1.
    parameter bit    BOOT_EN             = 1'b0,
    // Enables the synthetic §6.1 container↔CALL launch fixture.
    parameter bit    CONTAINER_CALL_SPIKE_EN = 1'b0,
    // CHECK_ENTRY_RETURN: when 1, capture the return value at the frame
    // depth where the module entry function returns to module scope
    // (frame_active_depth == 1).  Used by image-boot tests where the
    // module code calls the entry function and receives its result at
    // depth 1 rather than the classic depth==0 base-frame return.
    parameter bit    CHECK_ENTRY_RETURN  = 1'b0,
    // Phase C: instantiate the two-core top (pycore_excore_system) instead
    // of the legacy single-core pycore_system when set, so every existing
    // image flow can also be run on the new system unchanged. FW_HEX is
    // the assembled excore firmware (see excore/tools/asm_rv32.py);
    // ignored when EXCORE_EN=0.
    parameter bit    EXCORE_EN           = 1'b0,
    parameter string FW_HEX              = "",
    // When >= 0, assert trap_req_count == this value at the end of the run
    // (see trap_req_count above). Sentinel -1 (default) skips the check.
    parameter int    EXPECTED_TRAP_REQ_COUNT = -1,
    // When non-empty and EXCORE_EN=1, capture CONSOLE_TX (MMIO 0xF0) writes
    // to this path for stdout golden diffs (print tests).
    parameter string STDOUT_PATH             = ""
);
    localparam logic [3:0] CORE_S_WB = 4'd4;

    logic clk;
    logic rst_n;
    logic trap_out;
    logic [4:0]  trap_code;
    logic [63:0] cycle_count;
    logic dbg_wb_we;
    logic [7:0]  dbg_wb_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry;

    // Counts completed trap_req handshakes (i.e. how many times pycore
    // handed a recoverable trap to the excore) — 0 always under
    // EXCORE_EN=0. Used by Phase C tests that assert an exact excore
    // grant count (e.g. "exactly 3 traps fired" / "excore never granted
    // memory").
    int unsigned trap_req_count;

    // g_dut wraps the DUT instance so both branches resolve to the same
    // hierarchical prefix (g_dut.dut.core.*) regardless of which top is
    // selected -- every hierarchical reference below is written against
    // that fixed shape.
    generate
        if (EXCORE_EN) begin : g_dut
            pycore_excore_system #(
                .PROG_HEX  (PROG_HEX),
                .STRING_HEX(STRING_HEX),
                .DMEM_HEX  (DMEM_HEX),
                .HEAP_INIT_PTR(HEAP_INIT_PTR),
                .BOOT_EN(BOOT_EN),
                .CONTAINER_CALL_SPIKE_EN(CONTAINER_CALL_SPIKE_EN),
                .EXCORE_EN(1'b1),
                .FW_HEX(FW_HEX)
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

            initial trap_req_count = 0;
            always @(posedge clk) begin
                if (dut.trap_req_valid && dut.trap_req_ready) begin
                    trap_req_count <= trap_req_count + 1;
                end
            end

            // Console capture: spy MMIO writes to CONSOLE_TX @ 0xF0.
            int stdout_fd;
            initial begin
                stdout_fd = 0;
                if (STDOUT_PATH.len() > 0) begin
                    stdout_fd = $fopen(STDOUT_PATH, "w");
                    if (stdout_fd == 0) begin
                        $error("[FAIL] could not open STDOUT_PATH=%s", STDOUT_PATH);
                        $finish;
                    end
                end
            end
            // Capture on the MMIO request pulse (req is one-cycle; ack is
            // registered one cycle later so req&&ack never overlaps).
            always @(posedge clk) begin
                if ((stdout_fd != 0) &&
                    dut.ex_mmio_req && dut.ex_mmio_we &&
                    (dut.ex_mmio_addr[7:0] == 8'hF0)) begin
                    $fwrite(stdout_fd, "%c", dut.ex_mmio_wdata[7:0]);
                    $fflush(stdout_fd);
                end
            end
            final begin
                if (stdout_fd != 0) begin
                    $fclose(stdout_fd);
                end
            end
        end else begin : g_dut
            pycore_system #(
                .PROG_HEX  (PROG_HEX),
                .STRING_HEX(STRING_HEX),
                .DMEM_HEX  (DMEM_HEX),
                .HEAP_INIT_PTR(HEAP_INIT_PTR),
                .BOOT_EN(BOOT_EN),
                .CONTAINER_CALL_SPIKE_EN(CONTAINER_CALL_SPIKE_EN)
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

            initial trap_req_count = 0; // pycore_system never marshals a trap
        end
    endgenerate

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
        bit trap_seen;
        logic [PYCORE_ENTRY_WIDTH-1:0] return_entry;
        logic [3:0]                    got_tag;
        logic [PYCORE_VAL_WIDTH-1:0]   got_val;
        logic [4:0]                    got_trap;

        clk = 1'b0;
        rst_n = 1'b0;
        return_seen = 0;
        trap_seen = 0;
        got_trap = PY_TRAP_NONE;

        #20;
        rst_n = 1'b1;

        for (i = 0; i < MAX_CYCLES; i++) begin
            @(posedge clk);

            if (trap_out) begin
                trap_seen = 1;
                got_trap  = trap_code;
                break;
            end

            if ((g_dut.dut.core.state_r == CORE_S_WB) &&
                (g_dut.dut.core.cur_opcode_r == PY_OP_RETURN_VALUE) &&
                (g_dut.dut.core.frame_active_depth ==
                    (CHECK_ENTRY_RETURN ? 8'd1 : 8'd0))) begin
                // Under image boot the module frame's terminal return is
                // typically `return None` (RETURN_VALUE with a NONE-tagged
                // TOS).  Filter those out so the check locks onto the
                // entry function's real return value.
                if (CHECK_ENTRY_RETURN &&
                    pycore_is_none(pycore_get_tag(g_dut.dut.core.rs1_r),
                                   pycore_get_val(g_dut.dut.core.rs1_r))) begin
                    // Skip and keep waiting for the entry return.
                end else begin
                    return_seen  = 1;
                    return_entry = g_dut.dut.core.rs1_r;
                    break;
                end
            end
        end

        if (i >= MAX_CYCLES) begin
            $error("[FAIL] still running at MAX_CYCLES=%0d (possible probe hang) — %s",
                   MAX_CYCLES, PROG_HEX);
            $finish;
        end

        if (EXPECT_TRAP) begin
            check(trap_seen,
                  $sformatf("expected trap code %0d but program returned cleanly (%s)",
                            EXPECTED_TRAP_CODE, PROG_HEX));
            check(!return_seen,
                  $sformatf("expected trap but saw clean return (%s)", PROG_HEX));
            check(got_trap == EXPECTED_TRAP_CODE,
                  $sformatf("trap code mismatch: expected %0d got %0d (%s)",
                            EXPECTED_TRAP_CODE, got_trap, PROG_HEX));
            $display("PASS: %s — trapped code=%0d cycles=%0d",
                     PROG_HEX, got_trap, cycle_count);
        end else begin
            if (trap_seen) begin
                $error("[FAIL] program trapped (code=%0d) at cycle %0d — %s",
                       got_trap, cycle_count, PROG_HEX);
                $finish;
            end

            check(return_seen,
                  $sformatf("program did not complete within MAX_CYCLES=%0d (%s)",
                            MAX_CYCLES, PROG_HEX));

            got_tag = pycore_get_tag(return_entry);
            got_val = pycore_get_val(return_entry);

            check(got_tag == EXPECTED_TAG,
                  $sformatf("tag mismatch: expected %0d got %0d (%s)",
                            EXPECTED_TAG, got_tag, PROG_HEX));
            check(got_val == EXPECTED_VALUE,
                  $sformatf("value mismatch: expected 0x%0h got 0x%0h (%s)",
                            EXPECTED_VALUE, got_val, PROG_HEX));

            $display("PASS: %s — tag=%0d value=0x%0h cycles=%0d",
                     PROG_HEX, got_tag, got_val[63:0], cycle_count);
        end

        if (EXPECTED_TRAP_REQ_COUNT >= 0) begin
            check(trap_req_count == EXPECTED_TRAP_REQ_COUNT,
                  $sformatf("trap_req_count mismatch: expected %0d got %0d (%s)",
                            EXPECTED_TRAP_REQ_COUNT, trap_req_count, PROG_HEX));
        end
        $finish;
    end
endmodule
