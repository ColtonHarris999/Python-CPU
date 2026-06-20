`include "pycore_defs.svh"

// A tiled memory bank: BLOCK_COUNT fixed-size SRAM blocks behind a single
// byte-addressed req/ack port. BLOCK_SHIFT (log2 bytes per block) is the primary
// retarget knob, so 2 KB / 4 KB / 8 KB blocks change one parameter.
//
// Address decode (byte address):
//   block_idx = addr[ADDR_WIDTH-1:BLOCK_SHIFT]
//   block_off = addr[BLOCK_SHIFT-1:0]
//   word_idx  = block_off >> log2(DATA_WIDTH/8)
//
// Timing: a request is accepted combinationally; `ack` (and registered `rdata`)
// return exactly one cycle later, matching the synchronous-SRAM block latency.
// An out-of-range block, or a write to a READ_ONLY bank, raises `fault` with the
// ack so the master can convert it into a trap without hanging.
module pycore_mem_bank #(
    parameter int    DATA_WIDTH  = 64,
    parameter int    ADDR_WIDTH  = 32,
    parameter int    BLOCK_SHIFT = 12,
    parameter int    BLOCK_COUNT = 4,
    parameter int    READ_ONLY   = 0,
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

    localparam int BYTES_PER_WORD  = DATA_WIDTH / 8;
    localparam int WORD_SHIFT      = $clog2(BYTES_PER_WORD);
    localparam int WORDS_PER_BLOCK = (1 << BLOCK_SHIFT) / BYTES_PER_WORD;
    localparam int WORD_ADDR_W     = $clog2(WORDS_PER_BLOCK);
    localparam int BLOCK_IDX_W     = (BLOCK_COUNT <= 1) ? 1 : $clog2(BLOCK_COUNT);

    logic [ADDR_WIDTH-BLOCK_SHIFT-1:0] block_idx;
    logic [WORD_ADDR_W-1:0]            word_idx;
    logic                              req_fault;
    logic [BLOCK_IDX_W-1:0]            sel_idx;

    assign block_idx = addr[ADDR_WIDTH-1:BLOCK_SHIFT];
    assign word_idx  = addr[BLOCK_SHIFT-1:WORD_SHIFT];
    assign req_fault = req && (((block_idx >= BLOCK_COUNT) ||
                               (we && (READ_ONLY != 0))));
    assign sel_idx   = (block_idx < BLOCK_COUNT) ? block_idx[BLOCK_IDX_W-1:0]
                                                 : '0;

    logic [DATA_WIDTH-1:0] blk_rdata [0:BLOCK_COUNT-1];

    genvar g;
    generate
        for (g = 0; g < BLOCK_COUNT; g++) begin : gen_block
            logic blk_we;
            assign blk_we = req && we && (READ_ONLY == 0) &&
                            !req_fault && (block_idx == g);

            pycore_mem_block #(
                .DATA_WIDTH(DATA_WIDTH),
                .DEPTH(WORDS_PER_BLOCK),
                .INIT_HEX((g == 0) ? INIT_HEX : "")
            ) blk (
                .clk(clk),
                .we(blk_we),
                .addr(word_idx),
                .wdata(wdata),
                .rdata(blk_rdata[g])
            );
        end
    endgenerate

    logic                   ack_q;
    logic                   fault_q;
    logic [BLOCK_IDX_W-1:0] sel_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_q   <= 1'b0;
            fault_q <= 1'b0;
            sel_q   <= '0;
        end else begin
            ack_q   <= req;
            fault_q <= req_fault;
            sel_q   <= sel_idx;
        end
    end

    assign ack   = ack_q;
    assign fault = fault_q;
    assign rdata = blk_rdata[sel_q];

endmodule
