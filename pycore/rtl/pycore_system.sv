`include "pycore_defs.svh"

// Simulation/integration top: the CPU core wired to its instruction and data
// memory banks. The testbench instantiates this module, not the core directly,
// so memory lives outside the core as real master/slave connections instead of
// a loopback wire.
//
// The constant ROM has been removed.  LOAD_CONST reads co_consts through
// S_CONTAINER; the module image builder (image_from_source.py) preloads
// dmem with the code object + constants tuple + globals dict, and the CPU
// walks the boot record at reset (S_BOOT) when BOOT_EN=1.
module pycore_system #(
    parameter int    ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W      = PYCORE_DMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT      = PYCORE_BLOCK_SHIFT,
    parameter int    IMEM_BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter int    DMEM_BLOCK_COUNT = PYCORE_DMEM_BLOCK_COUNT,
    parameter string PROG_HEX         = "pycore/programs/program.hex",
    parameter string CODE_RAM_HEX     = "",
    parameter string STRING_HEX       = "pycore/programs/string_mem.hex",
    parameter string DMEM_HEX         = "",
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE,
    parameter bit    BOOT_EN          = 1'b1,
    parameter bit    CONTAINER_CALL_SPIKE_EN = 1'b0
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    output logic        trap_out_o,
    output logic [4:0]  trap_code_o,
    output logic [63:0] cycle_count_o,
    output logic                          dbg_wb_we_o,
    output logic [7:0]                    dbg_wb_addr_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry_o
);

    // imem master <-> bank
    logic                   imem_req;
    logic                   imem_we;
    logic [ADDR_WIDTH-1:0]  imem_addr;
    logic [IMEM_DATA_W-1:0] imem_wdata;
    logic                   imem_ack;
    logic [IMEM_DATA_W-1:0] imem_rdata;
    logic                   imem_fault;
    logic [PYCORE_LINE_BYTES*8-1:0] imem_line;
    logic                   imem_line_valid;

    // dmem master <-> bank
    logic                   dmem_req;
    logic                   dmem_we;
    logic                   dmem_line;
    logic [DMEM_DATA_W/8-1:0] dmem_wstrb;
    logic [ADDR_WIDTH-1:0]  dmem_addr;
    logic [DMEM_DATA_W-1:0] dmem_wdata;
    logic [PYCORE_LINE_BYTES*8-1:0] dmem_wline;
    logic                   dmem_ack;
    logic [DMEM_DATA_W-1:0] dmem_rdata;
    logic                   dmem_fault;

    // +CACHE_EN= overrides PYCORE_CACHE_EN at sim time. Wired to L2
    // (and later L1s) as the combinational pass-through switch.
    bit cache_en_sim /* verilator public */;
    int mem_latency_sim /* verilator public */;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [PYCORE_PERF_CNT_WIDTH-1:0] l1i_hit_count, l1i_miss_count, l1i_writeback_count;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_hit_count, l1d_miss_count, l1d_writeback_count;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_frame_hit_count, l1d_frame_miss_count;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_hit_count, l2_miss_count, l2_writeback_count;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] codc_hit_count, codc_miss_count, codc_fill_count, codc_flush_count;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] gic_hit_count, gic_miss_count, gic_fill_count, gic_flush_count;
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        int cache_en_i;
        cache_en_i = int'(PYCORE_CACHE_EN);
        void'($value$plusargs("CACHE_EN=%d", cache_en_i));
        void'($value$plusargs("PYCORE_CACHE_EN=%d", cache_en_i));
        cache_en_sim = (cache_en_i != 0);
    end

    assign l1i_writeback_count = '0;

    initial begin
        mem_latency_sim = PYCORE_RAM_T_FIRST_CI;
        void'($value$plusargs("MEM_LATENCY=%d", mem_latency_sim));
    end

    pycore_core #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W),
        .STRING_HEX(STRING_HEX),
        .HEAP_INIT_PTR(HEAP_INIT_PTR),
        .BOOT_EN(BOOT_EN),
        .CONTAINER_CALL_SPIKE_EN(CONTAINER_CALL_SPIKE_EN)
    ) core (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .imem_req_o(imem_req),
        .imem_we_o(imem_we),
        .imem_addr_o(imem_addr),
        .imem_wdata_o(imem_wdata),
        .imem_ack_i(imem_ack),
        .imem_rdata_i(imem_rdata),
        .imem_fault_i(imem_fault),
        .imem_line_i(imem_line),
        .imem_line_valid_i(imem_line_valid),
        .dmem_req_o(dmem_req),
        .dmem_we_o(dmem_we),
        .dmem_line_o(dmem_line),
        .dmem_wstrb_o(dmem_wstrb),
        .dmem_addr_o(dmem_addr),
        .dmem_wdata_o(dmem_wdata),
        .dmem_wline_o(dmem_wline),
        .dmem_ack_i(dmem_ack),
        .dmem_rdata_i(dmem_rdata),
        .dmem_fault_i(dmem_fault),
        // EXCORE_EN defaults to 0 (not overridden here): this legacy
        // single-core top never enters S_TRAP_MARSHAL/S_TRAP_WAIT, so the
        // trap_req/trap_res ports are simply tied off.
        .trap_req_valid_o(),
        .trap_req_ready_i(1'b0),
        .trap_req_code_o(),
        .trap_req_pc_o(),
        .trap_req_instr_o(),
        .trap_req_heap_ptr_o(),
        .trap_req_entry_count_o(),
        .trap_req_entries_o(),
        .trap_res_valid_i(1'b0),
        .trap_res_ready_o(),
        .trap_res_code_i('0),
        .trap_res_fatal_code_i('0),
        .trap_res_pop_count_i('0),
        .trap_res_push_count_i('0),
        .trap_res_heap_ptr_i('0),
        .trap_res_entries_i('{'0, '0}),
        .trap_out_o(trap_out_o),
        .trap_code_o(trap_code_o),
        .cycle_count_o(cycle_count_o),
        .dbg_wb_we_o(dbg_wb_we_o),
        .dbg_wb_addr_o(dbg_wb_addr_o),
        .dbg_wb_entry_o(dbg_wb_entry_o),
        .codc_hit_count_o(codc_hit_count),
        .codc_miss_count_o(codc_miss_count),
        .codc_fill_count_o(codc_fill_count),
        .codc_flush_count_o(codc_flush_count),
        .gic_hit_count_o(gic_hit_count),
        .gic_miss_count_o(gic_miss_count),
        .gic_fill_count_o(gic_fill_count),
        .gic_flush_count_o(gic_flush_count)
    );

    pycore_mem_hier #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W),
        .PROG_HEX(PROG_HEX),
        .CODE_RAM_HEX(CODE_RAM_HEX),
        .DMEM_HEX(DMEM_HEX)
    ) mem_hier (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .cache_en_i(cache_en_sim),
        .t_first_i(mem_latency_sim),
        .imem_req_i(imem_req),
        .imem_we_i(imem_we),
        .imem_wstrb_i({IMEM_DATA_W/8{1'b1}}),
        .imem_addr_i(imem_addr),
        .imem_wdata_i(imem_wdata),
        .imem_ack_o(imem_ack),
        .imem_rdata_o(imem_rdata),
        .imem_fault_o(imem_fault),
        .imem_line_o(imem_line),
        .imem_line_valid_o(imem_line_valid),
        .dmem_req_i(dmem_req),
        .dmem_we_i(dmem_we),
        .dmem_line_i(dmem_line),
        .dmem_wstrb_i(dmem_wstrb),
        .dmem_addr_i(dmem_addr),
        .dmem_wdata_i(dmem_wdata),
        .dmem_wline_i(dmem_wline),
        .dmem_ack_o(dmem_ack),
        .dmem_rdata_o(dmem_rdata),
        .dmem_fault_o(dmem_fault),
        .excore_req_i(1'b0),
        .excore_we_i(1'b0),
        .excore_wstrb_i('0),
        .excore_addr_i('0),
        .excore_wdata_i('0),
        .excore_ack_o(),
        .excore_rdata_o(),
        .excore_fault_o(),
        .flush_req_i(1'b0),
        .inv_req_i(1'b0),
        .flush_done_o(),
        .inv_done_o(),
        .l1d_idle_o(),
        .l1i_hit_count_o(l1i_hit_count),
        .l1i_miss_count_o(l1i_miss_count),
        .l1d_hit_count_o(l1d_hit_count),
        .l1d_miss_count_o(l1d_miss_count),
        .l1d_writeback_count_o(l1d_writeback_count),
        .l1d_frame_hit_count_o(l1d_frame_hit_count),
        .l1d_frame_miss_count_o(l1d_frame_miss_count),
        .l2_hit_count_o(l2_hit_count),
        .l2_miss_count_o(l2_miss_count),
        .l2_writeback_count_o(l2_writeback_count)
    );

endmodule
