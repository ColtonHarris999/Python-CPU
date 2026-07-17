`include "pycore_defs.svh"

// Two-core system top level (Phase C). pycore_system.sv remains the
// single-core top for legacy testbenches; this module additionally
// instantiates the excore, the trap mailbox, and the memory-ownership
// grant mux described in pycore/docs/architecture.md.
//
// Memory ownership: pycore and the excore share one dmem bank
// (pycore_mem_bank) through a registered grant mux (`mem_owner_r`),
// never through cycle-level arbitration — pycore is frozen in
// S_TRAP_MARSHAL/S_TRAP_WAIT while EXCORE owns memory, and the excore's
// firmware is parked (polling MB_STATUS) while PYCORE owns it, so the two
// masters are never both active. A $fatal check below still verifies the
// non-owner never raises req, as a simulation-time correctness backstop.
//
// Instruction memories are NOT shared: pycore's imem and the excore's
// private firmware imem are each their own array (Harvard per core).
module pycore_excore_system #(
    parameter int    ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W      = PYCORE_DMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT      = PYCORE_BLOCK_SHIFT,
    parameter int    IMEM_BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter int    DMEM_BLOCK_COUNT = PYCORE_DMEM_BLOCK_COUNT,
    parameter string PROG_HEX         = "pycore/programs/program.hex",
    parameter string STRING_HEX       = "pycore/programs/string_mem.hex",
    parameter string DMEM_HEX         = "",
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE,
    parameter bit    BOOT_EN          = 1'b1,
    // Two-core top: EXCORE_EN defaults to 1 here (unlike pycore_core's own
    // default of 0, which is what pycore_system's legacy instantiation
    // relies on).
    parameter bit    EXCORE_EN        = 1'b1,
    parameter string FW_HEX           = "",
    parameter int    MAX_TRAP_ENTRIES = 3,
    parameter int    MAX_RES_ENTRIES  = 2
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    output logic        trap_out_o,
    output logic [3:0]  trap_code_o,
    output logic [63:0] cycle_count_o,
    output logic                          dbg_wb_we_o,
    output logic [7:0]                    dbg_wb_addr_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry_o
);

    // ---- pycore imem <-> its own private bank ----------------------------
    logic                   imem_req, imem_we, imem_ack, imem_fault;
    logic [ADDR_WIDTH-1:0]  imem_addr;
    logic [IMEM_DATA_W-1:0] imem_wdata, imem_rdata;

    // ---- pycore's raw dmem master port (pre-grant-mux) --------------------
    logic                   core_dmem_req, core_dmem_we, core_dmem_ack, core_dmem_fault;
    logic [ADDR_WIDTH-1:0]  core_dmem_addr;
    logic [DMEM_DATA_W-1:0] core_dmem_wdata, core_dmem_rdata;

    // ---- excore's raw slot-port master (pre-grant-mux) --------------------
    logic          sp_req, sp_we, sp_ack, sp_fault;
    logic [31:0]   sp_addr;
    logic [127:0]  sp_wdata, sp_rdata;

    // ---- trap_req / trap_res between pycore_core and trap_mailbox --------
    logic          trap_req_valid, trap_req_ready;
    logic [3:0]    trap_req_code;
    logic [31:0]   trap_req_pc;
    logic [39:0]   trap_req_instr;
    logic [31:0]   trap_req_heap_ptr;
    logic [2:0]    trap_req_entry_count;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_req_entries [0:MAX_TRAP_ENTRIES-1];

    logic          trap_res_valid, trap_res_ready;
    logic [3:0]    trap_res_code, trap_res_fatal_code;
    logic [2:0]    trap_res_pop_count;
    logic [1:0]    trap_res_push_count;
    logic [31:0]   trap_res_heap_ptr;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_res_entries [0:MAX_RES_ENTRIES-1];

    // ---- mailbox <-> excore_mmio -------------------------------------------
    logic          mb_trap_pending;
    logic [3:0]    mb_trap_code;
    logic [31:0]   mb_pc;
    logic [7:0]    mb_opcode;
    logic [31:0]   mb_arg;
    logic [31:0]   mb_heap_ptr;
    logic [2:0]    mb_entry_count;
    logic [PYCORE_ENTRY_WIDTH-1:0] mb_entries [0:MAX_TRAP_ENTRIES-1];

    logic          res_go;
    logic [3:0]    res_code, res_fatal_code;
    logic [2:0]    res_pop_count;
    logic [1:0]    res_push_count;
    logic [31:0]   res_heap_ptr;
    logic [PYCORE_ENTRY_WIDTH-1:0] res_entries [0:MAX_RES_ENTRIES-1];

    // ---- excore_cpu <-> excore_mmio ----------------------------------------
    logic          ex_mmio_req, ex_mmio_we, ex_mmio_ack;
    logic [31:0]   ex_mmio_addr, ex_mmio_wdata, ex_mmio_rdata;
    logic          ex_fault;
    logic [31:0]   ex_fault_pc;

    // =========================================================================
    // pycore
    // =========================================================================
    pycore_core #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W),
        .STRING_HEX(STRING_HEX),
        .HEAP_INIT_PTR(HEAP_INIT_PTR),
        .BOOT_EN(BOOT_EN),
        .EXCORE_EN(EXCORE_EN),
        .MAX_TRAP_ENTRIES(MAX_TRAP_ENTRIES),
        .MAX_RES_ENTRIES(MAX_RES_ENTRIES)
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
        .dmem_req_o(core_dmem_req),
        .dmem_we_o(core_dmem_we),
        .dmem_addr_o(core_dmem_addr),
        .dmem_wdata_o(core_dmem_wdata),
        .dmem_ack_i(core_dmem_ack),
        .dmem_rdata_i(core_dmem_rdata),
        .dmem_fault_i(core_dmem_fault),
        .trap_req_valid_o(trap_req_valid),
        .trap_req_ready_i(trap_req_ready),
        .trap_req_code_o(trap_req_code),
        .trap_req_pc_o(trap_req_pc),
        .trap_req_instr_o(trap_req_instr),
        .trap_req_heap_ptr_o(trap_req_heap_ptr),
        .trap_req_entry_count_o(trap_req_entry_count),
        .trap_req_entries_o(trap_req_entries),
        .trap_res_valid_i(trap_res_valid),
        .trap_res_ready_o(trap_res_ready),
        .trap_res_code_i(trap_res_code),
        .trap_res_fatal_code_i(trap_res_fatal_code),
        .trap_res_pop_count_i(trap_res_pop_count),
        .trap_res_push_count_i(trap_res_push_count),
        .trap_res_heap_ptr_i(trap_res_heap_ptr),
        .trap_res_entries_i(trap_res_entries),
        .trap_out_o(trap_out_o),
        .trap_code_o(trap_code_o),
        .cycle_count_o(cycle_count_o),
        .dbg_wb_we_o(dbg_wb_we_o),
        .dbg_wb_addr_o(dbg_wb_addr_o),
        .dbg_wb_entry_o(dbg_wb_entry_o)
    );

    pycore_imem #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(IMEM_DATA_W),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(IMEM_BLOCK_COUNT),
        .INIT_HEX(PROG_HEX)
    ) imem (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .req_i(imem_req),
        .we_i(imem_we),
        .addr_i(imem_addr),
        .wdata_i(imem_wdata),
        .ack_o(imem_ack),
        .rdata_o(imem_rdata),
        .fault_o(imem_fault)
    );

    // =========================================================================
    // excore
    // =========================================================================
    excore_cpu #(
        .FW_HEX(FW_HEX)
    ) excore (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .mmio_req_o(ex_mmio_req),
        .mmio_we_o(ex_mmio_we),
        .mmio_addr_o(ex_mmio_addr),
        .mmio_wdata_o(ex_mmio_wdata),
        .mmio_ack_i(ex_mmio_ack),
        .mmio_rdata_i(ex_mmio_rdata),
        .fault_o(ex_fault),
        .fault_pc_o(ex_fault_pc)
    );

    excore_mmio #(
        .MAX_TRAP_ENTRIES(MAX_TRAP_ENTRIES),
        .MAX_RES_ENTRIES(MAX_RES_ENTRIES)
    ) excore_mmio_inst (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .cpu_req_i(ex_mmio_req),
        .cpu_we_i(ex_mmio_we),
        .cpu_addr_i(ex_mmio_addr),
        .cpu_wdata_i(ex_mmio_wdata),
        .cpu_ack_o(ex_mmio_ack),
        .cpu_rdata_o(ex_mmio_rdata),
        .mb_trap_pending_i(mb_trap_pending),
        .mb_trap_code_i(mb_trap_code),
        .mb_pc_i(mb_pc),
        .mb_opcode_i(mb_opcode),
        .mb_arg_i(mb_arg),
        .mb_heap_ptr_i(mb_heap_ptr),
        .mb_entry_count_i(mb_entry_count),
        .mb_entries_i(mb_entries),
        .res_go_o(res_go),
        .res_code_o(res_code),
        .res_fatal_code_o(res_fatal_code),
        .res_pop_count_o(res_pop_count),
        .res_push_count_o(res_push_count),
        .res_heap_ptr_o(res_heap_ptr),
        .res_entries_o(res_entries),
        .sp_req_o(sp_req),
        .sp_we_o(sp_we),
        .sp_addr_o(sp_addr),
        .sp_wdata_o(sp_wdata),
        .sp_ack_i(sp_ack),
        .sp_rdata_i(sp_rdata),
        .sp_fault_i(sp_fault)
    );

    trap_mailbox #(
        .MAX_TRAP_ENTRIES(MAX_TRAP_ENTRIES),
        .MAX_RES_ENTRIES(MAX_RES_ENTRIES)
    ) trap_mbox (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .trap_req_valid_i(trap_req_valid),
        .trap_req_ready_o(trap_req_ready),
        .trap_req_code_i(trap_req_code),
        .trap_req_pc_i(trap_req_pc),
        .trap_req_instr_i(trap_req_instr),
        .trap_req_heap_ptr_i(trap_req_heap_ptr),
        .trap_req_entry_count_i(trap_req_entry_count),
        .trap_req_entries_i(trap_req_entries),
        .trap_res_valid_o(trap_res_valid),
        .trap_res_ready_i(trap_res_ready),
        .trap_res_code_o(trap_res_code),
        .trap_res_fatal_code_o(trap_res_fatal_code),
        .trap_res_pop_count_o(trap_res_pop_count),
        .trap_res_push_count_o(trap_res_push_count),
        .trap_res_heap_ptr_o(trap_res_heap_ptr),
        .trap_res_entries_o(trap_res_entries),
        .mb_trap_pending_o(mb_trap_pending),
        .mb_trap_code_o(mb_trap_code),
        .mb_pc_o(mb_pc),
        .mb_opcode_o(mb_opcode),
        .mb_arg_o(mb_arg),
        .mb_heap_ptr_o(mb_heap_ptr),
        .mb_entry_count_o(mb_entry_count),
        .mb_entries_o(mb_entries),
        .res_go_i(res_go),
        .ex_res_code_i(res_code),
        .ex_res_fatal_code_i(res_fatal_code),
        .ex_res_pop_count_i(res_pop_count),
        .ex_res_push_count_i(res_push_count),
        .ex_res_heap_ptr_i(res_heap_ptr),
        .ex_res_entries_i(res_entries)
    );

    // =========================================================================
    // Memory-ownership grant mux (dmem is the only shared memory).
    // =========================================================================
    localparam logic OWNER_PYCORE = 1'b0;
    localparam logic OWNER_EXCORE = 1'b1;
    logic mem_owner_r;

    // Owner flips to EXCORE exactly when the trap_req handshake completes
    // (mailbox accepts the request); back to PYCORE exactly when the
    // trap_res handshake completes (pycore acks the result).
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            mem_owner_r <= OWNER_PYCORE;
        end else if ((mem_owner_r == OWNER_PYCORE) && trap_req_valid && trap_req_ready) begin
            mem_owner_r <= OWNER_EXCORE;
        end else if ((mem_owner_r == OWNER_EXCORE) && trap_res_valid && trap_res_ready) begin
            mem_owner_r <= OWNER_PYCORE;
        end
    end

    logic                   dmem_req, dmem_we, dmem_ack, dmem_fault;
    logic [ADDR_WIDTH-1:0]  dmem_addr;
    logic [DMEM_DATA_W-1:0] dmem_wdata, dmem_rdata;

    // sp_wdata_o/sp_rdata_i are fixed at 128 bits (one pycore dmem slot);
    // DMEM_DATA_W matches PYCORE_DMEM_DATA_WIDTH (128) by default and must
    // not be changed independently of the slot-port width.
    assign dmem_req   = (mem_owner_r == OWNER_PYCORE) ? core_dmem_req   : sp_req;
    assign dmem_we    = (mem_owner_r == OWNER_PYCORE) ? core_dmem_we    : sp_we;
    assign dmem_addr  = (mem_owner_r == OWNER_PYCORE) ? core_dmem_addr  : sp_addr;
    assign dmem_wdata = (mem_owner_r == OWNER_PYCORE) ? core_dmem_wdata : sp_wdata;

    assign core_dmem_ack   = (mem_owner_r == OWNER_PYCORE) ? dmem_ack   : 1'b0;
    assign core_dmem_rdata = dmem_rdata;
    assign core_dmem_fault = (mem_owner_r == OWNER_PYCORE) ? dmem_fault : 1'b0;

    assign sp_ack   = (mem_owner_r == OWNER_EXCORE) ? dmem_ack   : 1'b0;
    assign sp_rdata = dmem_rdata;
    assign sp_fault = (mem_owner_r == OWNER_EXCORE) ? dmem_fault : 1'b0;

    // Simulation-time correctness backstop: the non-owner must never raise
    // req while it does not hold the grant (see the module header comment
    // — this should be structurally impossible given pycore freezes in
    // S_TRAP_MARSHAL/S_TRAP_WAIT and the excore firmware only issues slot-
    // port transactions while handling a trap).
    always_ff @(posedge clk_i) begin
        if (rst_n_i) begin
            if ((mem_owner_r == OWNER_EXCORE) && core_dmem_req) begin
                $fatal(1, "pycore_excore_system: pycore raised dmem req while EXCORE owns memory");
            end
            if ((mem_owner_r == OWNER_PYCORE) && sp_req) begin
                $fatal(1, "pycore_excore_system: excore raised slot-port req while PYCORE owns memory");
            end
            if (ex_fault) begin
                $fatal(1, "pycore_excore_system: excore_cpu raised fault_o (unsupported instruction) at pc=0x%0h",
                       ex_fault_pc);
            end
        end
    end

    pycore_dmem #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DMEM_DATA_W),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(DMEM_BLOCK_COUNT),
        .INIT_HEX(DMEM_HEX)
    ) dmem (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .req_i(dmem_req),
        .we_i(dmem_we),
        .addr_i(dmem_addr),
        .wdata_i(dmem_wdata),
        .ack_o(dmem_ack),
        .rdata_o(dmem_rdata),
        .fault_o(dmem_fault)
    );

endmodule
