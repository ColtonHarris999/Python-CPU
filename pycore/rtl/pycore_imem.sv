`include "pycore_defs.svh"

// Instruction memory bank wrapper (Harvard, read-mostly). Each instruction is a
// 64-bit slot (40-bit folded word zero-padded to 8 bytes). The fetch unit drives
// byte addresses; writes are rejected (READ_ONLY) and surface as a fault.
module pycore_imem #(
    parameter int    ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH  = PYCORE_IMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT = PYCORE_BLOCK_SHIFT,
    parameter int    BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter string INIT_HEX    = "pycore/programs/program.hex"
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
        .READ_ONLY(1),
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
