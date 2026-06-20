`include "pycore_defs.svh"

// Data memory bank wrapper (Harvard, read/write). Access granularity is one
// 128-bit value per transaction in v1 (16-byte aligned); the MEM stage enforces
// alignment before issuing a request.
module pycore_dmem #(
    parameter int    ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH  = PYCORE_DMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT = PYCORE_BLOCK_SHIFT,
    parameter int    BLOCK_COUNT = PYCORE_DMEM_BLOCK_COUNT,
    parameter string INIT_HEX    = ""
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  req,
    input  logic                  we,
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [DATA_WIDTH-1:0] wdata,
    output logic                  ack,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic                  fault
);

    pycore_mem_bank #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(BLOCK_COUNT),
        .READ_ONLY(0),
        .INIT_HEX(INIT_HEX)
    ) bank (
        .clk(clk),
        .rst_n(rst_n),
        .req(req),
        .we(we),
        .addr(addr),
        .wdata(wdata),
        .ack(ack),
        .rdata(rdata),
        .fault(fault)
    );

endmodule
