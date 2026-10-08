`include "pycore_defs.svh"

// Routes Harvard imem (64-bit), L1D-down / dmem (128-bit), and the excore
// slot port onto one unified 128-bit L2 port. Instruction addresses are
// relocated to PYCORE_CODE_ADDR_BASE so they cannot alias data in the L2.
//
// Priority: dmem (L1D) > excore > imem. Fetch is stalled outside S_FETCH,
// so L1D-down and L1I-down never raise req in the same cycle; L1I hits
// never reach this mux. Excore attaches at L2 (P3), never at L1D. A master request is captured the cycle `req`
// is high. `l2_req_o` is held until `l2_ack_i`. Master `ack_o` is a
// one-cycle pulse the cycle after L2 acks — extra occupancy, same §0
// contract.
//
// Pipe mode: a dmem request with dmem_pipe_i (L1D's non-blocking fills)
// passes straight through to the L2's pipelined port. dmem_gnt_o is the
// L2's grant and responses come back in the same cycle, with
// dmem_last_o. The xbar stays with dmem until every pipelined request has
// answered; the other masters wait, as they do behind an ordinary request.
module pycore_mem_xbar #(
    parameter int    ADDR_WIDTH    = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W   = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W   = PYCORE_DMEM_DATA_WIDTH,
    parameter logic [31:0] CODE_BASE = PYCORE_CODE_ADDR_BASE
) (
    input  logic                    clk_i,
    input  logic                    rst_n_i,

    input  logic                    imem_req_i,
    input  logic                    imem_we_i,
    input  logic [IMEM_DATA_W/8-1:0] imem_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   imem_addr_i,
    input  logic [IMEM_DATA_W-1:0]  imem_wdata_i,
    output logic                    imem_ack_o,
    output logic [IMEM_DATA_W-1:0]  imem_rdata_o,
    output logic [PYCORE_LINE_BYTES*8-1:0] imem_rline_o,
    output logic                    imem_fault_o,

    input  logic                    dmem_req_i,
    input  logic                    dmem_we_i,
    input  logic [DMEM_DATA_W/8-1:0] dmem_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   dmem_addr_i,
    input  logic [DMEM_DATA_W-1:0]  dmem_wdata_i,
    input  logic                    dmem_line_i,
    input  logic [PYCORE_LINE_BYTES*8-1:0] dmem_wline_i,
    input  logic                    dmem_pipe_i,
    output logic                    dmem_gnt_o,
    output logic                    dmem_last_o,
    output logic                    dmem_ack_o,
    output logic [DMEM_DATA_W-1:0]  dmem_rdata_o,
    output logic                    dmem_fault_o,

    input  logic                    excore_req_i,
    input  logic                    excore_we_i,
    input  logic [DMEM_DATA_W/8-1:0] excore_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   excore_addr_i,
    input  logic [DMEM_DATA_W-1:0]  excore_wdata_i,
    output logic                    excore_gnt_o,
    output logic                    excore_ack_o,
    output logic [DMEM_DATA_W-1:0]  excore_rdata_o,
    output logic                    excore_fault_o,

    output logic                    l2_req_o,
    output logic                    l2_we_o,
    output logic [DMEM_DATA_W/8-1:0] l2_wstrb_o,
    output logic [ADDR_WIDTH-1:0]   l2_addr_o,
    output logic [DMEM_DATA_W-1:0]  l2_wdata_o,
    output logic                    l2_line_o,
    output logic [PYCORE_LINE_BYTES*8-1:0] l2_wline_o,
    output logic                    l2_pipe_o,
    input  logic                    l2_gnt_i,
    input  logic                    l2_last_i,
    input  logic                    l2_ack_i,
    input  logic [DMEM_DATA_W-1:0]  l2_rdata_i,
    input  logic [PYCORE_LINE_BYTES*8-1:0] l2_rline_i,
    input  logic                    l2_fault_i
);
    typedef enum logic [1:0] { G_NONE, G_IMEM, G_DMEM, G_EXCORE } grant_e;
    grant_e grant_r;
    logic   imem_hi_r;
    logic   imem_ack_r;
    logic   dmem_ack_r;
    logic   excore_ack_r;
    logic   fault_hold_r;
    logic [DMEM_DATA_W-1:0] rdata_hold_r;
    logic [PYCORE_LINE_BYTES*8-1:0] rline_hold_r;
    // Set when an excore request is accepted; cleared only after req
    // drops, so a level request is not captured twice (slot port).
    logic excore_lock_r;

    logic                    l2_req_r;
    logic                    l2_we_r;
    logic [DMEM_DATA_W/8-1:0] l2_wstrb_r;
    logic [ADDR_WIDTH-1:0]   l2_addr_r;
    logic [DMEM_DATA_W-1:0]  l2_wdata_r;
    logic                    l2_line_r;
    logic [PYCORE_LINE_BYTES*8-1:0] l2_wline_r;

    logic take_dmem;
    logic take_excore;
    logic take_imem;
    logic imem_hi;
    logic [ADDR_WIDTH-1:0] imem_uaddr;
    logic idle_take;

    // Pipe mode: pmode_r while pipelined requests are outstanding; pmode
    // also covers the cycle that opens it, so the first request passes
    // through at once.
    logic       pmode_r, pmode, pipe_take;
    logic [3:0] pcnt_r;
    assign idle_take = (grant_r == G_NONE) && !l2_req_r && !pmode_r &&
                       !imem_ack_r && !dmem_ack_r && !excore_ack_r;
    assign pmode     = pmode_r || (idle_take && dmem_req_i && dmem_pipe_i);
    assign pipe_take = pmode && dmem_req_i && dmem_pipe_i && l2_gnt_i;
    assign take_dmem   = idle_take && dmem_req_i && !dmem_pipe_i;
    assign take_excore = idle_take && !dmem_req_i && excore_req_i && !excore_lock_r;
    assign take_imem   = idle_take && !dmem_req_i && !excore_req_i && imem_req_i;
    assign imem_uaddr = ADDR_WIDTH'(CODE_BASE) + imem_addr_i;
    assign imem_hi    = imem_uaddr[3];

    assign l2_req_o   = pmode ? (dmem_req_i && dmem_pipe_i) : (l2_req_r && !l2_ack_i);
    assign l2_pipe_o  = pmode;
    assign l2_we_o    = pmode ? dmem_we_i    : l2_we_r;
    assign l2_wstrb_o = pmode ? dmem_wstrb_i : l2_wstrb_r;
    assign l2_addr_o  = pmode ? dmem_addr_i  : l2_addr_r;
    assign l2_wdata_o = pmode ? dmem_wdata_i : l2_wdata_r;
    assign l2_line_o  = pmode ? dmem_line_i  : l2_line_r;
    assign l2_wline_o = pmode ? dmem_wline_i : l2_wline_r;

    assign dmem_gnt_o   = pmode && l2_gnt_i;
    assign dmem_ack_o   = pmode_r ? l2_ack_i : dmem_ack_r;
    assign dmem_last_o  = pmode_r ? l2_last_i : 1'b1;
    assign dmem_rdata_o = pmode_r ? l2_rdata_i : rdata_hold_r;
    assign dmem_fault_o = pmode_r ? (l2_ack_i && l2_fault_i) : (dmem_ack_r && fault_hold_r);

    assign excore_gnt_o   = take_excore;
    assign excore_ack_o   = excore_ack_r;
    assign excore_rdata_o = rdata_hold_r;
    assign excore_fault_o = excore_ack_r && fault_hold_r;

    assign imem_ack_o   = imem_ack_r;
    assign imem_rdata_o = imem_hi_r ? rdata_hold_r[127:64] : rdata_hold_r[63:0];
    assign imem_rline_o = rline_hold_r;
    assign imem_fault_o = imem_ack_r && fault_hold_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            grant_r      <= G_NONE;
            imem_hi_r    <= 1'b0;
            imem_ack_r   <= 1'b0;
            dmem_ack_r   <= 1'b0;
            excore_ack_r <= 1'b0;
            fault_hold_r <= 1'b0;
            rdata_hold_r <= '0;
            rline_hold_r <= '0;
            excore_lock_r <= 1'b0;
            l2_req_r     <= 1'b0;
            l2_we_r      <= 1'b0;
            l2_wstrb_r   <= '0;
            l2_addr_r    <= '0;
            l2_wdata_r   <= '0;
            l2_line_r    <= 1'b0;
            l2_wline_r   <= '0;
            pmode_r      <= 1'b0;
            pcnt_r       <= '0;
        end else begin
            begin
                logic [3:0] n;
                n = pcnt_r + (pipe_take ? 4'd1 : 4'd0)
                           - ((pmode_r && l2_ack_i && l2_last_i) ? 4'd1 : 4'd0);
                pcnt_r  <= n;
                pmode_r <= pmode && (n != 4'd0);
            end
            imem_ack_r   <= 1'b0;
            dmem_ack_r   <= 1'b0;
            excore_ack_r <= 1'b0;
            if (!excore_req_i)
                excore_lock_r <= 1'b0;
            else if (take_excore)
                excore_lock_r <= 1'b1;
            if (take_dmem) begin
                grant_r    <= G_DMEM;
                imem_hi_r  <= 1'b0;
                l2_req_r   <= 1'b1;
                l2_we_r    <= dmem_we_i;
                l2_wstrb_r <= dmem_wstrb_i;
                l2_addr_r  <= dmem_addr_i;
                l2_wdata_r <= dmem_wdata_i;
                l2_line_r  <= dmem_line_i;
                l2_wline_r <= dmem_wline_i;
            end else if (take_excore) begin
                grant_r    <= G_EXCORE;
                imem_hi_r  <= 1'b0;
                l2_req_r   <= 1'b1;
                l2_we_r    <= excore_we_i;
                l2_wstrb_r <= excore_wstrb_i;
                l2_addr_r  <= excore_addr_i;
                l2_wdata_r <= excore_wdata_i;
                l2_line_r  <= 1'b0;
                l2_wline_r <= '0;
            end else if (take_imem) begin
                grant_r    <= G_IMEM;
                imem_hi_r  <= imem_hi;
                l2_req_r   <= 1'b1;
                l2_we_r    <= imem_we_i;
                l2_wstrb_r <= imem_hi ? {8'hFF, 8'h00} : {8'h00, 8'hFF};
                l2_addr_r  <= {imem_uaddr[ADDR_WIDTH-1:4], 4'b0};
                l2_wdata_r <= imem_hi ? {imem_wdata_i, 64'b0}
                                      : {64'b0, imem_wdata_i};
                l2_line_r  <= 1'b0;
                l2_wline_r <= '0;
            end else if (l2_req_r && l2_ack_i) begin
                rdata_hold_r <= l2_rdata_i;
                rline_hold_r <= l2_rline_i;
                fault_hold_r <= l2_fault_i;
                imem_ack_r   <= (grant_r == G_IMEM);
                dmem_ack_r   <= (grant_r == G_DMEM);
                excore_ack_r <= (grant_r == G_EXCORE);
                l2_req_r     <= 1'b0;
                grant_r      <= G_NONE;
            end
        end
    end
endmodule
