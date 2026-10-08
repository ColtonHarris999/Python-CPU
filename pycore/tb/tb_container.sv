`include "pycore_defs.svh"
`include "gc_shadow_check.sv"

// Testbench for container (LIST/DICT/TUPLE) operations and image-boot
// programs. Compile-time parameters remain for unit/legacy flows; image
// CI uses one Verilator binary plus runtime plusargs:
//
//   +PROG_HEX= +DMEM_HEX= +CODE_RAM_HEX= +FW_HEX=
//   +HEAP_INIT_PTR= +CODE_RAM_INIT_SLOT= +BOOT_EN= +CHECK_ENTRY_RETURN=
//   +EXPECTED_TAG= +EXPECTED_VALUE= +MAX_CYCLES=
//   +EXPECT_TRAP= +EXPECTED_TRAP_CODE= +EXPECTED_TRAP_REQ_COUNT=
//   +CHECK_RF_SPILL_COUNT= +CONTAINER_CALL_SPIKE_EN= +STDOUT_PATH=
//   +CACHE_EN= +MEM_LATENCY=
//   +PHASE_MARKS= +HEARTBEAT=
//
// PHASE_MARKS=1 (two-core only) turns CONSOLE_TX bytes 0x01..0x07 into
// `PHASE_MARK` lines stamped with the perf counters below instead of
// writing them to STDOUT_PATH; `pycore_cli.py exec` brackets on-device
// compile() and exec() with them. HEARTBEAT=N prints a `HEARTBEAT` line
// every N cycles so a long run can show progress.
//
// EXCORE_EN still selects the generate (single-core vs two-core top), so
// those two topologies are compiled once each.
//
// When EXPECT_TRAP is set, the test PASSES iff trap_out fires with
// trap_code == EXPECTED_TRAP_CODE before MAX_CYCLES, and FAILS on a clean
// return. When EXPECT_TRAP == 0, any trap is a failure (legacy behavior).
module tb_container #(
    parameter string PROG_HEX       = "pycore/programs/list_build_index.hex",
    parameter string CODE_RAM_HEX   = "",
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
    localparam logic [4:0] CORE_S_TRAP_MARSHAL = 5'd10;
    localparam logic [4:0] CORE_S_TRAP_WAIT    = 5'd11;

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

    // Perf counters for PHASE_MARK / PERF lines: instructions latched by
    // fetch (EXTENDED_ARG included) and cycles pycore spent handing a
    // recoverable trap to the excore and waiting for its result.
    longint unsigned instr_issued;
    longint unsigned excore_wait_cycles;
    initial begin
        instr_issued = 0;
        excore_wait_cycles = 0;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (g_dut.dut.core.latch_instr) begin
                instr_issued <= instr_issued + 1;
            end
            if ((g_dut.dut.core.state_r == CORE_S_TRAP_MARSHAL) ||
                (g_dut.dut.core.state_r == CORE_S_TRAP_WAIT)) begin
                excore_wait_cycles <= excore_wait_cycles + 1;
            end
        end
    end

    // Excore slot-port tap for the G5 shadow checker (zero on the single-core top).
    logic        gcs_ex_req, gcs_ex_we;
    logic [31:0] gcs_ex_addr;

    // g_dut wraps the DUT instance so both branches resolve to the same
    // hierarchical prefix (g_dut.dut.core.*) regardless of which top is
    // selected -- every hierarchical reference below is written against
    // that fixed shape.
    generate
        if (EXCORE_EN) begin : g_dut
            pycore_excore_system #(
                .PROG_HEX  (PROG_HEX),
                .CODE_RAM_HEX(CODE_RAM_HEX),
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

            assign gcs_ex_req  = dut.sp_req && (dut.mem_owner_r == dut.OWNER_EXCORE);
            assign gcs_ex_we   = dut.sp_we;
            assign gcs_ex_addr = dut.sp_addr;

            initial trap_req_count = 0;
            always @(posedge clk) begin
                if (dut.trap_req_valid && dut.trap_req_ready) begin
                    trap_req_count <= trap_req_count + 1;
                end
            end

            // Console capture: spy MMIO writes to CONSOLE_TX @ 0xF0.
            int stdout_fd;
            int phase_marks;
            initial begin
                string stdout_path;
                stdout_fd = 0;
                phase_marks = 0;
                void'($value$plusargs("PHASE_MARKS=%d", phase_marks));
                stdout_path = STDOUT_PATH;
                void'($value$plusargs("STDOUT_PATH=%s", stdout_path));
                if (stdout_path.len() > 0) begin
                    stdout_fd = $fopen(stdout_path, "w");
                    if (stdout_fd == 0) begin
                        $error("[FAIL] could not open STDOUT_PATH=%s", stdout_path);
                        $finish;
                    end
                end
            end
            // Capture on the MMIO request pulse (req is one-cycle; ack is
            // registered one cycle later so req&&ack never overlaps).
            // Pycore console (IO window). Excore CONSOLE_TX remains a debug port.
            always @(posedge clk) begin
                if (dut.mem_hier.console_emit_valid_o) begin
                    if ((phase_marks != 0) &&
                        (dut.mem_hier.console_emit_byte_o >= 8'h01) &&
                        (dut.mem_hier.console_emit_byte_o <= 8'h07)) begin
                        $display("PHASE_MARK id=%0d cycle=%0d instr=%0d excore_traps=%0d excore_wait=%0d l1i_hit=%0d l1i_miss=%0d l1d_hit=%0d l1d_miss=%0d",
                                 dut.mem_hier.console_emit_byte_o, cycle_count,
                                 instr_issued, trap_req_count,
                                 excore_wait_cycles,
                                 dut.l1i_hit_count, dut.l1i_miss_count,
                                 dut.l1d_hit_count, dut.l1d_miss_count);
                        $fflush();
                    end else if (stdout_fd != 0) begin
                        $fwrite(stdout_fd, "%c", dut.mem_hier.console_emit_byte_o);
                        $fflush(stdout_fd);
                    end
                end
            end
            always @(posedge clk) begin
                if (dut.ex_mmio_req && dut.ex_mmio_we &&
                    (dut.ex_mmio_addr[7:0] == 8'hF0)) begin
                    if ((phase_marks != 0) &&
                        (dut.ex_mmio_wdata[7:0] >= 8'h01) &&
                        (dut.ex_mmio_wdata[7:0] <= 8'h07)) begin
                        $display("PHASE_MARK id=%0d cycle=%0d instr=%0d excore_traps=%0d excore_wait=%0d l1i_hit=%0d l1i_miss=%0d l1d_hit=%0d l1d_miss=%0d",
                                 dut.ex_mmio_wdata[7:0], cycle_count,
                                 instr_issued, trap_req_count,
                                 excore_wait_cycles,
                                 dut.l1i_hit_count, dut.l1i_miss_count,
                                 dut.l1d_hit_count, dut.l1d_miss_count);
                        $fflush();
                    end else if (stdout_fd != 0) begin
                        $fwrite(stdout_fd, "%c", dut.ex_mmio_wdata[7:0]);
                        $fflush(stdout_fd);
                    end
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
                .CODE_RAM_HEX(CODE_RAM_HEX),
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
            int stdout_fd;
            int phase_marks;
            initial begin
                string stdout_path;
                stdout_fd = 0;
                phase_marks = 0;
                void'($value$plusargs("PHASE_MARKS=%d", phase_marks));
                stdout_path = STDOUT_PATH;
                void'($value$plusargs("STDOUT_PATH=%s", stdout_path));
                if (stdout_path.len() > 0) begin
                    stdout_fd = $fopen(stdout_path, "w");
                    if (stdout_fd == 0) begin
                        $error("[FAIL] could not open STDOUT_PATH=%s", stdout_path);
                        $finish;
                    end
                end
            end
            always @(posedge clk) begin
                if (dut.mem_hier.console_emit_valid_o) begin
                    if ((phase_marks != 0) &&
                        (dut.mem_hier.console_emit_byte_o >= 8'h01) &&
                        (dut.mem_hier.console_emit_byte_o <= 8'h07)) begin
                        $display("PHASE_MARK id=%0d cycle=%0d instr=%0d excore_traps=%0d excore_wait=%0d l1i_hit=%0d l1i_miss=%0d l1d_hit=%0d l1d_miss=%0d",
                                 dut.mem_hier.console_emit_byte_o, cycle_count,
                                 instr_issued, trap_req_count,
                                 excore_wait_cycles,
                                 dut.l1i_hit_count, dut.l1i_miss_count,
                                 dut.l1d_hit_count, dut.l1d_miss_count);
                    end else if (stdout_fd != 0) begin
                        $fwrite(stdout_fd, "%c", dut.mem_hier.console_emit_byte_o);
                        $fflush(stdout_fd);
                    end
                end
            end
            final begin
                if (stdout_fd != 0) $fclose(stdout_fd);
            end
            assign gcs_ex_req  = 1'b0;
            assign gcs_ex_we   = 1'b0;
            assign gcs_ex_addr = '0;
        end
    endgenerate

    gc_shadow_check gc_shadow (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .en_i(g_dut.dut.core.gc_en_sim),
        .gc_enter_i(g_dut.dut.core.state_r == 5'd17),
        .gc_done_i((g_dut.dut.core.state_r == 5'd19) && g_dut.dut.core.gc_done),
        .gc_state_i(g_dut.dut.core.gc_state),
        .free_valid_i(g_dut.dut.core.gc_free_range_valid),
        .free_base_i(g_dut.dut.core.gc_free_range_base),
        .free_len_i(g_dut.dut.core.gc_free_range_len),
        .heap_ptr_i(g_dut.dut.core.heap_ptr_r),
        .heap_limit_i(g_dut.dut.core.heap_limit_r),
        .core_req_i(g_dut.dut.core.dmem_req_o),
        .core_we_i(g_dut.dut.core.dmem_we_o),
        .core_addr_i(g_dut.dut.core.dmem_addr_o),
        .pc_i(g_dut.dut.core.cur_pc_r),
        .opcode_i(g_dut.dut.core.cur_opcode_r),
        .ex_req_i(gcs_ex_req),
        .ex_we_i(gcs_ex_we),
        .ex_addr_i(gcs_ex_addr)
    );

    always #5 clk = ~clk;

    // ---------------------------------------------------------------------
    // Garbage-collector monitor (planning/gc_plan.md §6.1, §10.2 G4).
    //   +GC_DUMP_EACH=<dir>  after collection n write <dir>/gc<n>.gcdump:
    //                        engine counters, the root set recorded here from
    //                        architectural state (independent of the RTL's
    //                        stream), and a coherent memory image
    //   +GC_DUMP_MAX=<n>     dump at most the first n collections (default 20)
    // ---------------------------------------------------------------------
    `define GC_MEMH g_dut.dut.mem_hier
    `include "gc_tb_util.svh"
    localparam logic [4:0] CORE_S_GC_ENTER = 5'd17;
    localparam logic [4:0] CORE_S_GC_RUN   = 5'd19;
    string       gc_dump_dir;
    int          gc_dump_max;
    int          gc_dump_n;
    logic [3:0]   gc_rt_tag [0:511];
    logic [127:0] gc_rt_val [0:511];
    int          gc_rt_n;
    logic [31:0] gc_free_before_tb;
    initial begin
        gc_dump_dir = "";
        gc_dump_max = 20;
        gc_dump_n = 0;
        void'($value$plusargs("GC_DUMP_EACH=%s", gc_dump_dir));
        void'($value$plusargs("GC_DUMP_MAX=%d", gc_dump_max));
    end

    task automatic gc_add_root(input logic [PYCORE_ENTRY_WIDTH-1:0] e);
        if (gc_rt_n < 512) begin
            gc_rt_tag[gc_rt_n] = pycore_get_tag(e);
            gc_rt_val[gc_rt_n] = pycore_get_val(e);
        end
        gc_rt_n++;
    endtask

    // Register roots in plan §3.3 order, then the RF ring [wm, tos).
    task automatic gc_record_roots();
        logic [7:0] i;
        gc_rt_n = 0;
        if (g_dut.dut.core.cur_code_r != 0)
            gc_add_root(pycore_make_entry(PY_TAG_CODE_OBJECT, {96'd0, g_dut.dut.core.cur_code_r}));
        if (g_dut.dut.core.globals_base_r != 0)
            gc_add_root(pycore_make_mut(PY_MUT_DICT, {32'd0, g_dut.dut.core.globals_base_r}, 1'b0));
        if (g_dut.dut.core.builtins_base_r != 0)
            gc_add_root(pycore_make_mut(PY_MUT_DICT, {32'd0, g_dut.dut.core.builtins_base_r}, 1'b0));
        if (g_dut.dut.core.cur_closure_r != 0)
            gc_add_root(pycore_make_entry(PY_TAG_TUPLE, g_dut.dut.core.cur_closure_r));
        if (g_dut.dut.core.active_exc_valid_r) gc_add_root(g_dut.dut.core.active_exc_r);
        if (g_dut.dut.core.call_exc_pending_r) gc_add_root(g_dut.dut.core.call_exc_handle_r);
        if (g_dut.dut.core.container_call_active_r) begin
            gc_add_root(g_dut.dut.core.container_call_saved_rs1_r);
            gc_add_root(g_dut.dut.core.container_call_saved_rs2_r);
            gc_add_root(g_dut.dut.core.container_proto_iter_r);
        end
        if (g_dut.dut.core.container_call_return_valid_r)
            gc_add_root(g_dut.dut.core.container_call_result_r);
        if (g_dut.dut.core.iter_exhaust_type_r != 0) gc_add_root(g_dut.dut.core.iter_exhaust_type_r);
        i = 8'(g_dut.dut.core.rf_wm_r);
        while (i != 8'(g_dut.dut.core.tos_r)) begin
            gc_add_root(g_dut.dut.core.regfile.rf[i]);
            i = i + 8'd1;
        end
    endtask

    //   +GC_LOG=1            one "[GC-LOG]" line per collection
    //   +GC_SITE_STATS=1     at exit, one "[GC-SITE]" line per allocation
    //                        context: first heap advance per instruction,
    //                        aborts, the collections and re-dispatches
    //                        they caused (planning/gc_plan.md G8, G9)
    localparam logic [4:0] CORE_S_CALL      = 5'd6;
    localparam logic [4:0] CORE_S_CONTAINER = 5'd8;
    localparam logic [4:0] CORE_S_STRACC    = 5'd12;
    localparam logic [4:0] CORE_S_GC_ALLOC  = 5'd20;
    bit          gc_log_en;
    bit          gc_site_en;
    int          site_alloc [string];
    int          site_abort [string];
    int          site_collect [string];
    int          site_redisp [string];
    logic [4:0]  site_state_q;
    logic [5:0]  site_cop_q, site_sop_q;
    logic [3:0]  site_var_q;
    logic [4:0]  site_phase_q;
    logic [6:0]  site_sub_q;
    logic [7:0]  site_opc_q;
    logic [31:0] site_hp_q;
    bit          site_abort_q, site_collect_seen;
    string       site_abort_key;
    string       site_stracc_hold;
    initial begin
        gc_log_en = $test$plusargs("GC_LOG=1");
        gc_site_en = $test$plusargs("GC_SITE_STATS=1");
        site_abort_q = 0; site_collect_seen = 0;
        site_abort_key = "";
        site_stracc_hold = "";
        site_sop_q = '0;
        site_var_q = '0;
    end

    function automatic string site_key(input logic [4:0] st, input logic [5:0] cop,
                                       input logic [4:0] ph, input logic [6:0] sub,
                                       input logic [5:0] sop, input logic [3:0] svar,
                                       input logic [7:0] opc);
        if (st == CORE_S_CONTAINER) return $sformatf("cont%0d", cop);
        if (st == CORE_S_CALL)      return $sformatf("call%0d.%0d", ph, sub);
        if (st == CORE_S_STRACC)    return $sformatf("stracc%0d.%0d", sop, svar);
        return $sformatf("state%0d.op%0d", st, opc);
    endfunction

    // Testbench bookkeeping: blocking assignments are intended here.
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (rst_n && gc_site_en) begin
            if (g_dut.dut.core.latch_instr)
                site_stracc_hold = "";
            // stracc_cmd_op defaults to CONCAT when no command is in flight
            // (`pycore_core.sv`). Latch the issued op so NEED_HEAP after
            // the pulse still names split/partition (G9 rows 34/35).
            if (g_dut.dut.core.stracc_cmd_valid) begin
                site_sop_q = g_dut.dut.core.stracc_cmd_op;
                site_var_q = 4'(g_dut.dut.core.stracc_cmd_var);
            end
            if (site_state_q == CORE_S_STRACC)
                site_stracc_hold = site_key(site_state_q, site_cop_q, site_phase_q,
                                            site_sub_q, site_sop_q, site_var_q, site_opc_q);
            // Count every bump. A CALL can allocate *args and **kwargs in
            // the same instruction; the first-only gate dropped row 30.
            if ((g_dut.dut.core.heap_ptr_r > site_hp_q) &&
                (site_state_q != CORE_S_GC_ALLOC)) begin
                string k;
                k = site_key(site_state_q, site_cop_q, site_phase_q, site_sub_q, site_sop_q, site_var_q, site_opc_q);
                site_alloc[k] = site_alloc.exists(k) ? site_alloc[k] + 1 : 1;
            end
            if (g_dut.dut.core.gc_abort_r && !site_abort_q) begin
                // NEED_HEAP from a CALL-launched STRACC aborts after
                // CALL_PHASE_GC_UNWIND (call25.*). Credit the STRACC op.
                if (site_stracc_hold.len() > 0)
                    site_abort_key = site_stracc_hold;
                // The binder reservation (B18) aborts for the *args tuple
                // and **kwargs dict before either is placed (rows 29/30).
                else if (g_dut.dut.core.gc_res_abort_r)
                    site_abort_key = g_dut.dut.core.gc_res_abort_kw_r ? "callres.kw" : "callres.args";
                else
                    site_abort_key = site_key(site_state_q, site_cop_q, site_phase_q, site_sub_q,
                                              site_sop_q, site_var_q, site_opc_q);
                site_abort[site_abort_key] = site_abort.exists(site_abort_key)
                                             ? site_abort[site_abort_key] + 1 : 1;
                site_collect_seen = 0;
            end
            if (g_dut.dut.core.gc_abort_r && !site_collect_seen &&
                (g_dut.dut.core.state_r == CORE_S_GC_ENTER)) begin
                site_collect[site_abort_key] = site_collect.exists(site_abort_key)
                                               ? site_collect[site_abort_key] + 1 : 1;
                site_collect_seen = 1;
            end
            if (!g_dut.dut.core.gc_abort_r && site_abort_q)
                site_redisp[site_abort_key] = site_redisp.exists(site_abort_key)
                                              ? site_redisp[site_abort_key] + 1 : 1;
            site_abort_q = g_dut.dut.core.gc_abort_r;
            site_state_q = g_dut.dut.core.state_r;
            site_cop_q   = g_dut.dut.core.container_op_r;
            site_phase_q = g_dut.dut.core.call_phase_r;
            site_sub_q   = g_dut.dut.core.call_sub_r;
            site_opc_q   = g_dut.dut.core.cur_opcode_r;
            site_hp_q    = g_dut.dut.core.heap_ptr_r;
        end
    end

    /* verilator lint_on BLKSEQ */

    task automatic gc_site_report();
        string k;
        if (!gc_site_en) return;
        if (site_alloc.first(k) != 0) do
            $display("[GC-SITE] key=%s allocs=%0d aborts=%0d collects=%0d redispatch=%0d", k,
                     site_alloc[k], site_abort.exists(k) ? site_abort[k] : 0,
                     site_collect.exists(k) ? site_collect[k] : 0,
                     site_redisp.exists(k) ? site_redisp[k] : 0);
        while (site_alloc.next(k) != 0);
        if (site_abort.first(k) != 0) do
            if (!site_alloc.exists(k))
                $display("[GC-SITE] key=%s allocs=0 aborts=%0d collects=%0d redispatch=%0d", k,
                         site_abort[k], site_collect.exists(k) ? site_collect[k] : 0,
                         site_redisp.exists(k) ? site_redisp[k] : 0);
        while (site_abort.next(k) != 0);
    endtask

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (rst_n && (g_dut.dut.core.state_r == CORE_S_GC_ENTER)) begin
            gc_record_roots();
            gc_free_before_tb = (g_dut.dut.core.heap_limit_r - g_dut.dut.core.heap_ptr_r)
                                + g_dut.dut.core.gc_list_free_r;
        end
        if (rst_n && (g_dut.dut.core.state_r == CORE_S_GC_RUN) && g_dut.dut.core.gc_done) begin
            if (gc_log_en)
                $display("[GC-LOG] n=%0d cycle=%0d pc=%0d reason=%s live=%0d free=%0d largest=%0d runs=%0d objects=%0d mark_cyc=%0d sweep_cyc=%0d",
                         g_dut.dut.core.gc_collections_r, cycle_count, g_dut.dut.core.cur_pc_r,
                         g_dut.dut.core.gc_explicit_r ? "explicit" :
                         g_dut.dut.core.gc_abort_r ? "alloc" :
                         g_dut.dut.core.gc_exit_req_r ? "exit" :
                         g_dut.dut.core.gc_boundary_req_r ? "boundary" : "other",
                         g_dut.dut.core.gc_live_bytes, g_dut.dut.core.gc_free_bytes,
                         g_dut.dut.core.gc_largest_size, g_dut.dut.core.gc_runs,
                         g_dut.dut.core.gc_objects, g_dut.dut.core.gc_mark_cyc,
                         g_dut.dut.core.gc_sweep_cyc);
            if (g_dut.dut.core.gc_bad_kind != 0 || g_dut.dut.core.gc_reserved_tag != 0 ||
                g_dut.dut.core.gc_wild_ptr != 0)
                $fatal(1, "[GC-INV] collection %0d saw bad_kind=%0d reserved_tag=%0d wild_ptr=%0d",
                       g_dut.dut.core.gc_collections_r, g_dut.dut.core.gc_bad_kind,
                       g_dut.dut.core.gc_reserved_tag, g_dut.dut.core.gc_wild_ptr);
            if ((gc_dump_dir.len() > 0) && (gc_dump_n < gc_dump_max)) begin
                int fd;
                string path;
                path = $sformatf("%s/gc%0d.gcdump", gc_dump_dir, gc_dump_n);
                fd = $fopen(path, "w");
                if (fd == 0) $fatal(1, "[FAIL] cannot open %s", path);
                $fwrite(fd, "# pycore-gc-dump v1\n");
                $fwrite(fd, "meta collection %0d\nmeta cycle %0d\nmeta pc %0d\n",
                        gc_dump_n, cycle_count, g_dut.dut.core.cur_pc_r);
                $fwrite(fd, "meta dyn_base %0d\nmeta heap_limit %0d\n",
                        g_dut.dut.core.heap_init_ptr_sim, g_dut.dut.core.gc_heap_limit_eff);
                $fwrite(fd, "meta spill_sp %0d\nmeta exc_sp %0d\nmeta frame_depth %0d\n",
                        g_dut.dut.core.spill_sp_r, g_dut.dut.core.exc_sp,
                        g_dut.dut.core.frame_active_depth);
                $fwrite(fd, "meta run_head %0d\nmeta live %0d\nmeta free %0d\nmeta largest %0d\nmeta largest_base %0d\nmeta runs %0d\n",
                        g_dut.dut.core.gc_run_head, g_dut.dut.core.gc_live_bytes,
                        g_dut.dut.core.gc_free_bytes, g_dut.dut.core.gc_largest_size,
                        g_dut.dut.core.gc_largest_base, g_dut.dut.core.gc_runs);
                $fwrite(fd, "meta roots %0d\nmeta objects %0d\nmeta stack_hw %0d\nmeta overflow %0d\n",
                        g_dut.dut.core.gc_roots_n, g_dut.dut.core.gc_objects,
                        g_dut.dut.core.gc_stack_hw, g_dut.dut.core.gc_stack_overflow);
                $fwrite(fd, "meta bad_kind %0d\nmeta reserved %0d\nmeta wild %0d\nmeta stash_en %0d\n",
                        g_dut.dut.core.gc_bad_kind, g_dut.dut.core.gc_reserved_tag,
                        g_dut.dut.core.gc_wild_ptr, g_dut.dut.core.gc_stash_sim);
                $fwrite(fd, "meta onchip %0d\n", g_dut.dut.core.u_gc.onchip_limit_r);
                $fwrite(fd, "meta stack_limit %0d\nmeta rescan_limit %0d\nmeta rescans %0d\n",
                        g_dut.dut.core.u_gc.stack_limit_r, g_dut.dut.core.u_gc.rescan_limit_r,
                        g_dut.dut.core.gc_rescans);
                $fwrite(fd, "meta extra_roots %0d\n", g_dut.dut.core.u_gc.extra_roots_r);
                $fwrite(fd, "meta keep_lo %0d\nmeta keep_hi %0d\nmeta rover_addr %0d\nmeta rover %0d\nmeta onchip_runs %0d\n",
                        g_dut.dut.core.u_gc.keep_lo_r, g_dut.dut.core.u_gc.keep_hi_r,
                        g_dut.dut.core.u_gc.rover_addr_r, g_dut.dut.core.u_gc.run_rover_r,
                        g_dut.dut.core.u_gc.run_onchip_n_r);
                $fwrite(fd, "meta free_before %0d\nmeta reclaimed %0d\n", gc_free_before_tb,
                        g_dut.dut.core.gc_free_bytes - g_dut.dut.core.gc_free_before_r);
                $fwrite(fd, "meta mark_cyc %0d\nmeta sweep_cyc %0d\nmeta port_busy_mark %0d\n",
                        g_dut.dut.core.gc_mark_cyc, g_dut.dut.core.gc_sweep_cyc,
                        g_dut.dut.core.gc_port_busy_mark);
                for (int k = 0; k < gc_rt_n && k < 512; k++)
                    $fwrite(fd, "root %0d %0h\n", gc_rt_tag[k], gc_rt_val[k]);
                gc_dump_memory(fd, g_dut.dut.core.gc_heap_limit_eff,
                               32'(g_dut.dut.core.frame_active_depth), g_dut.dut.core.spill_sp_r);
                begin
                    automatic int n;
                    automatic logic [31:0] slot, nxt;
                    n = int'(g_dut.dut.core.gc_run_onchip_n);
                    for (int i = 0; i < n; i++) begin
                        slot = PYCORE_GC_RUN_TABLE + (i << 4);
                        nxt = (i + 1 < n) ? (slot + 32'd16)
                            : g_dut.dut.core.gc_run_overflow_head;
                        $fwrite(fd, "mem %0h %0h\n", slot,
                                {PYCORE_GC_FREE_MAGIC,
                                 g_dut.dut.core.u_gc.run_size_q[i],
                                 nxt,
                                 g_dut.dut.core.u_gc.run_base_q[i]});
                    end
                end
                $fclose(fd);
                gc_dump_n++;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("[FAIL] %s", message);
                $finish;
            end
        end
    endtask

    initial begin
        longint i;
        bit return_seen;
        bit trap_seen;
        logic [PYCORE_ENTRY_WIDTH-1:0] return_entry;
        logic [3:0]                    got_tag;
        logic [PYCORE_VAL_WIDTH-1:0]   got_val;
        logic [4:0]                    got_trap;
        longint                        max_cycles;
        logic [3:0]                    expected_tag;
        logic [PYCORE_VAL_WIDTH-1:0]   expected_value;
        bit                            expect_trap;
        logic [4:0]                    expected_trap_code;
        bit                            check_entry_return;
        int                            expected_trap_req_count;
        int                            check_rf_spill_count;
        string                         prog_hex_disp;
        string                         expected_value_s;
        int                            k;
        int                            heartbeat;

        max_cycles = 64'(MAX_CYCLES);
        expected_tag = EXPECTED_TAG;
        expected_value = EXPECTED_VALUE;
        expect_trap = EXPECT_TRAP;
        expected_trap_code = EXPECTED_TRAP_CODE;
        check_entry_return = CHECK_ENTRY_RETURN;
        expected_trap_req_count = EXPECTED_TRAP_REQ_COUNT;
        check_rf_spill_count = -1;
        heartbeat = 0;
        prog_hex_disp = PROG_HEX;

        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        // +MAX_CYCLES_SCALE multiplies the cap only under a GC verification
        // plusarg (plan §6.1), so no normal run's cap ever moves.
        begin
            int scale;
            if ($value$plusargs("MAX_CYCLES_SCALE=%d", scale) && (scale > 1) &&
                ($test$plusargs("GC_AT_EXIT=1") || $test$plusargs("GC_AT_BOUNDARY_EVERY=") ||
                 $test$plusargs("GC_EVERY_N_RUNS=") || $test$plusargs("HEAP_LIMIT=") ||
                 $test$plusargs("HEAP_DYN_BYTES=") ||
                 $test$plusargs("GC_POISON=1")))
                max_cycles = max_cycles * longint'(scale);
        end
        void'($value$plusargs("EXPECTED_TAG=%d", expected_tag));
        // 128-bit goldens (e.g. UNARY_INVERT) do not fit in a 64-bit %d.
        if ($value$plusargs("EXPECTED_VALUE=%s", expected_value_s)) begin
            expected_value = '0;
            for (k = 0; k < expected_value_s.len(); k++) begin
                if (expected_value_s[k] >= "0" && expected_value_s[k] <= "9") begin
                    expected_value = expected_value * 128'd10
                        + 128'(expected_value_s[k] - "0");
                end
            end
        end
        void'($value$plusargs("EXPECT_TRAP=%d", expect_trap));
        void'($value$plusargs("EXPECTED_TRAP_CODE=%d", expected_trap_code));
        void'($value$plusargs("CHECK_ENTRY_RETURN=%d", check_entry_return));
        void'($value$plusargs("EXPECTED_TRAP_REQ_COUNT=%d",
                             expected_trap_req_count));
        void'($value$plusargs("CHECK_RF_SPILL_COUNT=%d",
                             check_rf_spill_count));
        void'($value$plusargs("PROG_HEX=%s", prog_hex_disp));
        void'($value$plusargs("HEARTBEAT=%d", heartbeat));

        begin
            int cache_en_disp;
            cache_en_disp = int'(PYCORE_CACHE_EN);
            void'($value$plusargs("CACHE_EN=%d", cache_en_disp));
            void'($value$plusargs("PYCORE_CACHE_EN=%d", cache_en_disp));
            $display("tb_container: CACHE_EN=%0d", cache_en_disp);
        end

        clk = 1'b0;
        rst_n = 1'b0;
        return_seen = 0;
        trap_seen = 0;
        got_trap = PY_TRAP_NONE;

        #20;
        rst_n = 1'b1;

        for (i = 0; i < max_cycles; i++) begin
            @(posedge clk);

            if ((heartbeat > 0) && (i > 0) && ((i % 64'(heartbeat)) == 0)) begin
                $display("HEARTBEAT cycle=%0d instr=%0d", cycle_count,
                         instr_issued);
                $fflush();
            end

            if (trap_out) begin
                trap_seen = 1;
                got_trap  = trap_code;
                break;
            end

            if ((g_dut.dut.core.state_r == CORE_S_WB) &&
                (g_dut.dut.core.cur_opcode_r == PY_OP_RETURN_VALUE)) begin
                // Image boot runs the module at depth 0 and the entry at
                // depth 1. The module may call other functions first; each
                // of those is also depth 1. Keep the latest non-None depth-1
                // return and stop on the module's own return. A None return
                // at depth 1 is not the entry value (entry programs return
                // a real result; the module's terminal return is None).
                if (check_entry_return) begin
                    if (g_dut.dut.core.frame_active_depth == 8'd0) begin
                        break;
                    end else if ((g_dut.dut.core.frame_active_depth == 8'd1) &&
                                 !pycore_is_none(
                                     pycore_get_tag(g_dut.dut.core.rs1_r),
                                     pycore_get_val(g_dut.dut.core.rs1_r))) begin
                        return_seen  = 1;
                        return_entry = g_dut.dut.core.rs1_r;
                    end
                end else if (g_dut.dut.core.frame_active_depth == 8'd0) begin
                    return_seen  = 1;
                    return_entry = g_dut.dut.core.rs1_r;
                    break;
                end
            end
        end

        if (i >= max_cycles) begin
            $error("[FAIL] still running at MAX_CYCLES=%0d (possible probe hang) — %s",
                   max_cycles, prog_hex_disp);
            $finish;
        end

        if (expect_trap) begin
            check(trap_seen,
                  $sformatf("expected trap code %0d but program returned cleanly (%s)",
                            expected_trap_code, prog_hex_disp));
            check(!return_seen,
                  $sformatf("expected trap but saw clean return (%s)", prog_hex_disp));
            check(got_trap == expected_trap_code,
                  $sformatf("trap code mismatch: expected %0d got %0d (%s)",
                            expected_trap_code, got_trap, prog_hex_disp));
            $display("PASS: %s — trapped code=%0d cycles=%0d",
                     prog_hex_disp, got_trap, cycle_count);
        end else begin
            if (trap_seen) begin
                $error("[FAIL] program trapped (code=%0d) at cycle %0d — %s",
                       got_trap, cycle_count, prog_hex_disp);
                $finish;
            end

            check(return_seen,
                  $sformatf("program did not complete within MAX_CYCLES=%0d (%s)",
                            max_cycles, prog_hex_disp));

            got_tag = pycore_get_tag(return_entry);
            got_val = pycore_get_val(return_entry);

            check(got_tag == expected_tag,
                  $sformatf("tag mismatch: expected %0d got %0d (%s)",
                            expected_tag, got_tag, prog_hex_disp));
            check(got_val == expected_value,
                  $sformatf("value mismatch: expected 0x%0h got 0x%0h (%s)",
                            expected_value, got_val, prog_hex_disp));

            $display("PASS: %s — tag=%0d value=0x%0h cycles=%0d",
                     prog_hex_disp, got_tag, got_val[63:0], cycle_count);
        end

        if (expected_trap_req_count >= 0) begin
            check(trap_req_count == expected_trap_req_count,
                  $sformatf("trap_req_count mismatch: expected %0d got %0d (%s)",
                            expected_trap_req_count, trap_req_count, prog_hex_disp));
        end
        $display("L1I hits=%0d misses=%0d  L1D hits=%0d misses=%0d wb=%0d frame_hits=%0d frame_misses=%0d",
                 g_dut.dut.l1i_hit_count, g_dut.dut.l1i_miss_count,
                 g_dut.dut.l1d_hit_count, g_dut.dut.l1d_miss_count,
                 g_dut.dut.l1d_writeback_count,
                 g_dut.dut.l1d_frame_hit_count, g_dut.dut.l1d_frame_miss_count);
        $display("CODC hits=%0d misses=%0d fills=%0d flushes=%0d",
                 g_dut.dut.core.codc_hit_count_o,
                 g_dut.dut.core.codc_miss_count_o,
                 g_dut.dut.core.codc_fill_count_o,
                 g_dut.dut.core.codc_flush_count_o);
        $display("GIC hits=%0d misses=%0d fills=%0d flushes=%0d",
                 g_dut.dut.core.gic_hit_count_o,
                 g_dut.dut.core.gic_miss_count_o,
                 g_dut.dut.core.gic_fill_count_o,
                 g_dut.dut.core.gic_flush_count_o);
        $display("RF spill_count=%0d wm=%0d tos=%0d resident=%0d",
                 g_dut.dut.core.rf_spill_count_r,
                 g_dut.dut.core.rf_wm_r,
                 g_dut.dut.core.tos_r,
                 g_dut.dut.core.rf_resident);
        if (check_rf_spill_count >= 0) begin
            check(int'(g_dut.dut.core.rf_spill_count_r) == check_rf_spill_count,
                  $sformatf("rf_spill_count mismatch: expected %0d got %0d (%s)",
                            check_rf_spill_count,
                            g_dut.dut.core.rf_spill_count_r, prog_hex_disp));
        end
        $display("fetch mem_req=%0d buf_hit=%0d",
                 g_dut.dut.core.fetch.mem_req_count_r,
                 g_dut.dut.core.fetch.buf_hit_count_r);
        $display("PERF instr=%0d excore_traps=%0d excore_wait=%0d accel_cfg=%h",
                 instr_issued, trap_req_count, excore_wait_cycles,
                 g_dut.dut.core.accel_cfg_r);
        if (g_dut.dut.core.gc_en_sim) begin
            $display("GC collections=%0d live=%0d free=%0d largest=%0d max_pause=%0d total_pause=%0d mark_cyc=%0d sweep_cyc=%0d port_busy_mark=%0d stack_hw=%0d stack_spills=%0d run_pops=%0d need_heap=%0d reclaimed=%0d stash_cyc=%0d zero_lines=%0d epoch=%0d mark_xacts=%0d",
                     g_dut.dut.core.gc_collections_r, g_dut.dut.core.gc_live_last_r,
                     g_dut.dut.core.gc_free_last_r, g_dut.dut.core.gc_largest_last_r,
                     g_dut.dut.core.gc_max_pause_r, g_dut.dut.core.gc_total_pause_r,
                     g_dut.dut.core.gc_mark_cyc_total_r, g_dut.dut.core.gc_sweep_cyc_total_r,
                     g_dut.dut.core.gc_port_busy_total_r, g_dut.dut.core.gc_stack_hw_max_r,
                     g_dut.dut.core.gc_spill_total_r, g_dut.dut.core.gc_run_pops_r,
                     g_dut.dut.core.gc_need_heap_cnt_r, g_dut.dut.core.gc_reclaimed_last_r,
                     g_dut.dut.core.gc_stash_cyc_total_r, g_dut.dut.core.gc_zero_lines_r,
                     g_dut.dut.core.gc_epoch_r, g_dut.dut.core.gc_mark_xacts_total_r);
            gc_site_report();
        end
        $finish;
    end
endmodule
