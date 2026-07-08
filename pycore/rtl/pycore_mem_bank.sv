`include "pycore_defs.svh"

// A tiled memory bank: BLOCK_COUNT fixed-size SRAM blocks behind a single
// byte-addressed req_i/ack_o port. BLOCK_SHIFT (log2 bytes per block) is the primary
// retarget knob, so 2 KB / 4 KB / 8 KB blocks change one parameter.
//
// Address decode (byte address):
//   block_idx = addr_i[ADDR_WIDTH-1:BLOCK_SHIFT]
//   block_off = addr_i[BLOCK_SHIFT-1:0]
//   word_idx  = block_off >> log2(DATA_WIDTH/8)
//
// Timing: a request is accepted combinationally; `ack_o` (and registered `rdata_o`)
// return exactly one cycle later, matching the synchronous-SRAM block latency.
// An out-of-range block, or a write to a READ_ONLY bank, raises `fault_o` with the
// ack_o so the master can convert it into a trap without hanging.
module pycore_mem_bank #(
    parameter int    DATA_WIDTH  = 64,
    parameter int    ADDR_WIDTH  = 32,
    parameter int    BLOCK_SHIFT = 12,
    parameter int    BLOCK_COUNT = 4,
    parameter int    READ_ONLY   = 0,
    parameter string INIT_HEX    = ""
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

    localparam int BYTES_PER_WORD  = DATA_WIDTH / 8;
    localparam int WORD_SHIFT      = $clog2(BYTES_PER_WORD);
    localparam int WORDS_PER_BLOCK = (1 << BLOCK_SHIFT) / BYTES_PER_WORD;
    localparam int WORD_ADDR_W     = $clog2(WORDS_PER_BLOCK);
    localparam int BLOCK_IDX_W     = (BLOCK_COUNT <= 1) ? 1 : $clog2(BLOCK_COUNT);

    logic [ADDR_WIDTH-BLOCK_SHIFT-1:0] block_idx;
    logic [WORD_ADDR_W-1:0]            word_idx;
    logic                              req_fault;
    logic [BLOCK_IDX_W-1:0]            sel_idx;

    assign block_idx = addr_i[ADDR_WIDTH-1:BLOCK_SHIFT];
    assign word_idx  = addr_i[BLOCK_SHIFT-1:WORD_SHIFT];
    assign req_fault = req_i && (((block_idx >= BLOCK_COUNT) ||
                               (we_i && (READ_ONLY != 0))));
    assign sel_idx   = (block_idx < BLOCK_COUNT) ? block_idx[BLOCK_IDX_W-1:0]
                                                 : '0;

    logic [DATA_WIDTH-1:0] blk_rdata [0:BLOCK_COUNT-1];

    genvar g;
    generate
        for (g = 0; g < BLOCK_COUNT; g++) begin : gen_block
            logic blk_we;
            assign blk_we = req_i && we_i && (READ_ONLY == 0) &&
                            !req_fault && (block_idx == g);

            pycore_mem_block #(
                .DATA_WIDTH(DATA_WIDTH),
                .DEPTH(WORDS_PER_BLOCK),
                .INIT_HEX((g == 0) ? INIT_HEX : "")
            ) blk (
                .clk_i(clk_i),
                .we_i(blk_we),
                .addr_i(word_idx),
                .wdata_i(wdata_i),
                .rdata_o(blk_rdata[g])
            );
        end
    endgenerate

    logic                   ack_r;
    logic                   fault_r;
    logic [BLOCK_IDX_W-1:0] sel_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            ack_r   <= 1'b0;
            fault_r <= 1'b0;
            sel_r   <= '0;
        end else begin
            ack_r   <= req_i;
            fault_r <= req_fault;
            sel_r   <= sel_idx;
        end
    end

    assign ack_o   = ack_r;
    assign fault_o = fault_r;
    assign rdata_o = blk_rdata[sel_r];

endmodule
