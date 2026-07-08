`include "pycore_defs.svh"

// Instruction memory bank wrapper (Harvard, read-mostly). Each instruction is a
// 64-bit slot (40-bit folded word zero-padded to 8 bytes). The fetch unit drives
// byte addresses; writes are rejected (READ_ONLY) and surface as a fault_o.
module pycore_imem #(
    parameter int    ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH  = PYCORE_IMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT = PYCORE_BLOCK_SHIFT,
    parameter int    BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter string INIT_HEX    = "pycore/programs/program.hex"
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,
    input  logic                  req_i,
    input  logic                  we_i,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] wdata_i,
    output logic                  ack_o,
    output logic [DATA_WIDTH-1:0] rdata_o,
    output logic                  fault_o
);

    pycore_mem_bank #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(BLOCK_COUNT),
        .READ_ONLY(1),
        .INIT_HEX(INIT_HEX)
    ) bank (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .req_i(req_i),
        .we_i(we_i),
        .addr_i(addr_i),
        .wdata_i(wdata_i),
        .ack_o(ack_o),
        .rdata_o(rdata_o),
        .fault_o(fault_o)
    );

endmodule
