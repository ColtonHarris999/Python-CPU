`include "pycore_defs.svh"

// Routes the Harvard imem (64-bit) and dmem (128-bit) masters onto one
// unified 128-bit L2 port. Instruction addresses are relocated to
// PYCORE_CODE_ADDR_BASE so they cannot alias data in the L2.
//
// A master request is captured into flops the cycle `req` is high (the
// master need not hold it). `l2_req_o` is then held until `l2_ack_i`,
// dropping combinationally on the ack cycle so L2/RAM do not see a second
// request on the completing posedge. Master `ack_o` is a one-cycle pulse
// the cycle after L2 acks — extra occupancy, same §0 contract.
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
    output logic                    imem_fault_o,

    input  logic                    dmem_req_i,
    input  logic                    dmem_we_i,
    input  logic [DMEM_DATA_W/8-1:0] dmem_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   dmem_addr_i,
    input  logic [DMEM_DATA_W-1:0]  dmem_wdata_i,
    output logic                    dmem_ack_o,
    output logic [DMEM_DATA_W-1:0]  dmem_rdata_o,
    output logic                    dmem_fault_o,

    output logic                    l2_req_o,
    output logic                    l2_we_o,
    output logic [DMEM_DATA_W/8-1:0] l2_wstrb_o,
    output logic [ADDR_WIDTH-1:0]   l2_addr_o,
    output logic [DMEM_DATA_W-1:0]  l2_wdata_o,
    input  logic                    l2_ack_i,
    input  logic [DMEM_DATA_W-1:0]  l2_rdata_i,
    input  logic                    l2_fault_i
);
    typedef enum logic [1:0] { G_NONE, G_IMEM, G_DMEM } grant_e;
    grant_e grant_r;
    logic   imem_hi_r;
    logic   imem_ack_r;
    logic   dmem_ack_r;
    logic   fault_hold_r;
    logic [DMEM_DATA_W-1:0] rdata_hold_r;

    logic                    l2_req_r;
    logic                    l2_we_r;
    logic [DMEM_DATA_W/8-1:0] l2_wstrb_r;
    logic [ADDR_WIDTH-1:0]   l2_addr_r;
    logic [DMEM_DATA_W-1:0]  l2_wdata_r;

    logic take_dmem;
    logic take_imem;
    logic imem_hi;
    logic [ADDR_WIDTH-1:0] imem_uaddr;

    assign take_dmem = (grant_r == G_NONE) && !l2_req_r &&
                       !imem_ack_r && !dmem_ack_r && dmem_req_i;
    assign take_imem = (grant_r == G_NONE) && !l2_req_r &&
                       !imem_ack_r && !dmem_ack_r &&
                       !dmem_req_i && imem_req_i;
    assign imem_uaddr = ADDR_WIDTH'(CODE_BASE) + imem_addr_i;
    assign imem_hi    = imem_uaddr[3];

    assign l2_req_o   = l2_req_r && !l2_ack_i;
    assign l2_we_o    = l2_we_r;
    assign l2_wstrb_o = l2_wstrb_r;
    assign l2_addr_o  = l2_addr_r;
    assign l2_wdata_o = l2_wdata_r;

    assign dmem_ack_o   = dmem_ack_r;
    assign dmem_rdata_o = rdata_hold_r;
    assign dmem_fault_o = dmem_ack_r && fault_hold_r;

    assign imem_ack_o   = imem_ack_r;
    assign imem_rdata_o = imem_hi_r ? rdata_hold_r[127:64] : rdata_hold_r[63:0];
    assign imem_fault_o = imem_ack_r && fault_hold_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            grant_r      <= G_NONE;
            imem_hi_r    <= 1'b0;
            imem_ack_r   <= 1'b0;
            dmem_ack_r   <= 1'b0;
            fault_hold_r <= 1'b0;
            rdata_hold_r <= '0;
            l2_req_r     <= 1'b0;
            l2_we_r      <= 1'b0;
            l2_wstrb_r   <= '0;
            l2_addr_r    <= '0;
            l2_wdata_r   <= '0;
        end else begin
            imem_ack_r <= 1'b0;
            dmem_ack_r <= 1'b0;
            if (take_dmem) begin
                grant_r    <= G_DMEM;
                imem_hi_r  <= 1'b0;
                l2_req_r   <= 1'b1;
                l2_we_r    <= dmem_we_i;
                l2_wstrb_r <= dmem_wstrb_i;
                l2_addr_r  <= dmem_addr_i;
                l2_wdata_r <= dmem_wdata_i;
            end else if (take_imem) begin
                grant_r    <= G_IMEM;
                imem_hi_r  <= imem_hi;
                l2_req_r   <= 1'b1;
                l2_we_r    <= imem_we_i;
                l2_wstrb_r <= imem_hi ? {8'hFF, 8'h00} : {8'h00, 8'hFF};
                l2_addr_r  <= {imem_uaddr[ADDR_WIDTH-1:4], 4'b0};
                l2_wdata_r <= imem_hi ? {imem_wdata_i, 64'b0}
                                      : {64'b0, imem_wdata_i};
            end else if (l2_req_r && l2_ack_i) begin
                rdata_hold_r <= l2_rdata_i;
                fault_hold_r <= l2_fault_i;
                imem_ack_r   <= (grant_r == G_IMEM);
                dmem_ack_r   <= (grant_r == G_DMEM);
                l2_req_r     <= 1'b0;
                grant_r      <= G_NONE;
            end
        end
    end
endmodule
