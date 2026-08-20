`include "pycore_defs.svh"

// Code memory region mux (Plan 1 P1).
//
// Presents one code address space to fetch while backing it with two banks:
// a read-only ROM (the image) below PYCORE_CODE_RAM_BYTE_BASE and a writable
// code RAM at or above it.  Drop-in replacement for pycore_imem, so both tops
// change only the module name and gain CODE_RAM_HEX.
//
// Both banks are the same pycore_mem_bank, so read latency and the ack
// handshake are identical whichever region is selected -- fetch needs no new
// stall state.  A request past the end of code RAM faults instead of wrapping.
module pycore_code_mem #(
    parameter int    ADDR_WIDTH      = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    BLOCK_SHIFT     = PYCORE_BLOCK_SHIFT,
    parameter int    ROM_BLOCK_COUNT = PYCORE_IMEM_BLOCK_COUNT,
    parameter int    RAM_BLOCK_COUNT = PYCORE_CODE_RAM_BLOCK_COUNT,
    parameter string INIT_HEX        = "pycore/programs/program.hex",
    parameter string CODE_RAM_HEX    = ""
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

    localparam logic [31:0] RAM_BYTE_BASE  = PYCORE_CODE_RAM_BYTE_BASE;
    localparam logic [31:0] RAM_BYTE_LIMIT =
        PYCORE_CODE_RAM_BYTE_BASE + (PYCORE_CODE_RAM_SLOTS << 3);

    logic sel_ram;
    logic out_of_range;
    logic [ADDR_WIDTH-1:0] ram_addr;

    logic rom_req, ram_req;
    logic rom_ack, ram_ack;
    logic rom_fault, ram_fault;
    logic [DATA_WIDTH-1:0] rom_rdata, ram_rdata;

    assign sel_ram      = (addr_i >= ADDR_WIDTH'(RAM_BYTE_BASE));
    assign out_of_range = (addr_i >= ADDR_WIDTH'(RAM_BYTE_LIMIT));
    assign ram_addr     = addr_i - ADDR_WIDTH'(RAM_BYTE_BASE);

    // Past the end of code RAM there is no bank to answer, so synthesise the
    // fault here (and still ack, so fetch cannot hang waiting for a response).
    assign rom_req = req_i && !sel_ram;
    assign ram_req = req_i && sel_ram && !out_of_range;

    assign ack_o = (req_i && out_of_range) ? 1'b1
                 : sel_ram                 ? ram_ack
                                           : rom_ack;
    assign rdata_o = sel_ram ? ram_rdata : rom_rdata;
    assign fault_o = (req_i && out_of_range) ? 1'b1
                   : sel_ram                 ? ram_fault
                                             : rom_fault;

    pycore_imem #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(ROM_BLOCK_COUNT),
        .INIT_HEX(INIT_HEX)
    ) rom (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .req_i(rom_req),
        .we_i(we_i && !sel_ram),
        .addr_i(addr_i),
        .wdata_i(wdata_i),
        .ack_o(rom_ack),
        .rdata_o(rom_rdata),
        .fault_o(rom_fault)
    );

    pycore_code_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .BLOCK_SHIFT(BLOCK_SHIFT),
        .BLOCK_COUNT(RAM_BLOCK_COUNT),
        .INIT_HEX(CODE_RAM_HEX)
    ) ram (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .req_i(ram_req),
        .we_i(we_i && sel_ram),
        .addr_i(ram_addr),
        .wdata_i(wdata_i),
        .ack_o(ram_ack),
        .rdata_o(ram_rdata),
        .fault_o(ram_fault)
    );

endmodule
