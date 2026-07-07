`include "pycore_defs.svh"

// Simulation/integration top: the CPU core wired to its instruction and data
// memory banks. The testbench instantiates this module, not the core directly,
// so memory lives outside the core as real master/slave connections instead of
// a loopback wire.
//
// The constant ROM has been removed. LOAD_CONST constants are now embedded
// directly in the instruction stream as 3-slot variable-length instructions
// and are reconstructed by the fetch unit, so no separate ROM is needed.
module pycore_system #(
    parameter int    ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W      = PYCORE_DMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT      = PYCORE_BLOCK_SHIFT,
    parameter int    IMEM_BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter int    DMEM_BLOCK_COUNT = PYCORE_DMEM_BLOCK_COUNT,
    parameter string PROG_HEX         = "pycore/programs/program.hex",
    parameter string STRING_HEX       = "pycore/programs/string_mem.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        trap_out,
    output logic [3:0]  trap_code,
    output logic [63:0] cycle_count,
    output logic                          dbg_wb_we,
    output logic [6:0]                    dbg_wb_addr,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry
);

    // imem master <-> bank
    logic                   imem_req;
    logic                   imem_we;
    logic [ADDR_WIDTH-1:0]  imem_addr;
    logic [IMEM_DATA_W-1:0] imem_wdata;
    logic                   imem_ack;
    logic [IMEM_DATA_W-1:0] imem_rdata;
    logic                   imem_fault;

    // dmem master <-> bank
    logic                   dmem_req;
    logic                   dmem_we;
    logic [ADDR_WIDTH-1:0]  dmem_addr;
    logic [DMEM_DATA_W-1:0] dmem_wdata;
    logic                   dmem_ack;
    logic [DMEM_DATA_W-1:0] dmem_rdata;
    logic                   dmem_fault;

    pycore_core #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W),
        .STRING_HEX(STRING_HEX)
    ) core (
        .clk(clk),
        .rst_n(rst_n),
        .imem_req(imem_req),
        .imem_we(imem_we),
        .imem_addr(imem_addr),
        .imem_wdata(imem_wdata),
        .imem_ack(imem_ack),
        .imem_rdata(imem_rdata),
        .imem_fault(imem_fault),
        .dmem_req(dmem_req),
        .dmem_we(dmem_we),
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_ack(dmem_ack),
        .dmem_rdata(dmem_rdata),
        .dmem_fault(dmem_fault),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .cycle_count(cycle_count),
        .dbg_wb_we(dbg_wb_we),
        .dbg_wb_addr(dbg_wb_addr),
        .dbg_wb_entry(dbg_wb_entry)
    );

    pycore_imem #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(IMEM_DATA_W),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(IMEM_BLOCK_COUNT),
        .INIT_HEX(PROG_HEX)
    ) imem (
        .clk(clk),
        .rst_n(rst_n),
        .req(imem_req),
        .we(imem_we),
        .addr(imem_addr),
        .wdata(imem_wdata),
        .ack(imem_ack),
        .rdata(imem_rdata),
        .fault(imem_fault)
    );

    pycore_dmem #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DMEM_DATA_W),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(DMEM_BLOCK_COUNT)
    ) dmem (
        .clk(clk),
        .rst_n(rst_n),
        .req(dmem_req),
        .we(dmem_we),
        .addr(dmem_addr),
        .wdata(dmem_wdata),
        .ack(dmem_ack),
        .rdata(dmem_rdata),
        .fault(dmem_fault)
    );

endmodule
