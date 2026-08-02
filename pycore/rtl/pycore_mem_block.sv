`include "pycore_defs.svh"

// One synchronous SRAM tile. Reads are registered (1-cycle latency) so the tile
// maps cleanly onto a real SRAM macro. A nonempty INIT_HEX loads a simulation
// image via $readmemh.
module pycore_mem_block #(
    parameter int    DATA_WIDTH = 64,
    parameter int    DEPTH      = 512,
    parameter string INIT_HEX   = "",
    parameter bit    INIT_ZERO  = 1'b1
) (
    input  logic                       clk_i,
    input  logic                       we_i,
    input  logic [$clog2(DEPTH)-1:0]   addr_i,
    input  logic [DATA_WIDTH-1:0]      wdata_i,
    output logic [DATA_WIDTH-1:0]      rdata_o
);

    // public_flat_rw: allow TB hierarchical dumps for the sim UI trace path.
    // Does not change simulation semantics.
    // verilator lint_off UNOPTFLAT
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1] /*verilator public_flat_rw*/;
    // verilator lint_on UNOPTFLAT

    initial begin
        int i;
        if (INIT_ZERO) begin
            for (i = 0; i < DEPTH; i++) begin
                mem[i] = '0;
            end
        end
        if (INIT_HEX != "") begin
            $readmemh(INIT_HEX, mem);
        end
    end

    always_ff @(posedge clk_i) begin
        if (we_i) begin
            mem[addr_i] <= wdata_i;
        end
        rdata_o <= mem[addr_i];
    end

endmodule
