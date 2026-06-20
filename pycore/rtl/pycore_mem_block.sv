`include "pycore_defs.svh"

// One synchronous SRAM tile. Reads are registered (1-cycle latency) so the tile
// maps cleanly onto a real SRAM macro. A nonempty INIT_HEX loads a simulation
// image via $readmemh.
module pycore_mem_block #(
    parameter int    DATA_WIDTH = 64,
    parameter int    DEPTH      = 512,
    parameter string INIT_HEX   = ""
) (
    input  logic                       clk,
    input  logic                       we,
    input  logic [$clog2(DEPTH)-1:0]   addr,
    input  logic [DATA_WIDTH-1:0]      wdata,
    output logic [DATA_WIDTH-1:0]      rdata
);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        int i;
        for (i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end
        if (INIT_HEX != "") begin
            $readmemh(INIT_HEX, mem);
        end
    end

    always_ff @(posedge clk) begin
        if (we) begin
            mem[addr] <= wdata;
        end
        rdata <= mem[addr];
    end

endmodule
