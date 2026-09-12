`include "pycore_defs.svh"

// P2 memory hierarchy: imem + dmem masters → xbar → unified L2 → RAM.
// Shared by pycore_system and pycore_excore_system so the two tops cannot
// drift. L1s attach in P3/P4 by wrapping the ports this module currently
// presents as going straight to L2.
module pycore_mem_hier #(
    parameter int    ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W      = PYCORE_DMEM_DATA_WIDTH,
    parameter string PROG_HEX         = "",
    parameter string CODE_RAM_HEX     = "",
    parameter string DMEM_HEX         = "",
    parameter int    L2_SIZE_BYTES    = PYCORE_L2_SIZE_BYTES,
    parameter int    L2_WAYS          = PYCORE_L2_WAYS,
    parameter int    L2_HIT_CYCLES    = PYCORE_L2_HIT_CYCLES
) (
    input  logic                    clk_i,
    input  logic                    rst_n_i,
    input  logic                    cache_en_i,
    input  int                      t_first_i,

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

    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_writeback_count_o
);
    logic                   l2_req, l2_we, l2_ack, l2_fault;
    logic [DMEM_DATA_W/8-1:0] l2_wstrb;
    logic [ADDR_WIDTH-1:0]  l2_addr;
    logic [DMEM_DATA_W-1:0] l2_wdata, l2_rdata;

    logic                   ram_req, ram_we, ram_line, ram_ack, ram_last, ram_fault;
    logic [DMEM_DATA_W/8-1:0] ram_wstrb;
    logic [ADDR_WIDTH-1:0]  ram_addr;
    logic [DMEM_DATA_W-1:0] ram_wdata, ram_rdata;

    pycore_mem_xbar #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W)
    ) xbar (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .imem_req_i(imem_req_i),
        .imem_we_i(imem_we_i),
        .imem_wstrb_i(imem_wstrb_i),
        .imem_addr_i(imem_addr_i),
        .imem_wdata_i(imem_wdata_i),
        .imem_ack_o(imem_ack_o),
        .imem_rdata_o(imem_rdata_o),
        .imem_fault_o(imem_fault_o),
        .dmem_req_i(dmem_req_i),
        .dmem_we_i(dmem_we_i),
        .dmem_wstrb_i(dmem_wstrb_i),
        .dmem_addr_i(dmem_addr_i),
        .dmem_wdata_i(dmem_wdata_i),
        .dmem_ack_o(dmem_ack_o),
        .dmem_rdata_o(dmem_rdata_o),
        .dmem_fault_o(dmem_fault_o),
        .l2_req_o(l2_req),
        .l2_we_o(l2_we),
        .l2_wstrb_o(l2_wstrb),
        .l2_addr_o(l2_addr),
        .l2_wdata_o(l2_wdata),
        .l2_ack_i(l2_ack),
        .l2_rdata_i(l2_rdata),
        .l2_fault_i(l2_fault)
    );

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DMEM_DATA_W),
        .SIZE_BYTES(L2_SIZE_BYTES),
        .LINE_BYTES(PYCORE_LINE_BYTES),
        .WAYS(L2_WAYS),
        .READ_ONLY(1'b0),
        .WRITE_BACK(1'b1),
        .HIT_CYCLES(L2_HIT_CYCLES)
    ) l2 (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .cache_en_i(cache_en_i),
        .req_i(l2_req),
        .we_i(l2_we),
        .wstrb_i(l2_wstrb),
        .addr_i(l2_addr),
        .wdata_i(l2_wdata),
        .ack_o(l2_ack),
        .rdata_o(l2_rdata),
        .fault_o(l2_fault),
        .down_req_o(ram_req),
        .down_we_o(ram_we),
        .down_line_o(ram_line),
        .down_wstrb_o(ram_wstrb),
        .down_addr_o(ram_addr),
        .down_wdata_o(ram_wdata),
        .down_ack_i(ram_ack),
        .down_last_i(ram_last),
        .down_rdata_i(ram_rdata),
        .down_fault_i(ram_fault),
        .inv_all_i(1'b0),
        .flush_all_i(1'b0),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(),
        .flush_done_o(),
        .hit_count_o(l2_hit_count_o),
        .miss_count_o(l2_miss_count_o),
        .writeback_count_o(l2_writeback_count_o)
    );

    pycore_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DMEM_DATA_W),
        .PROG_HEX(PROG_HEX),
        .CODE_RAM_HEX(CODE_RAM_HEX),
        .DMEM_HEX(DMEM_HEX)
    ) ram (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .t_first_i(t_first_i),
        .req_i(ram_req),
        .we_i(ram_we),
        .line_i(ram_line),
        .wstrb_i(ram_wstrb),
        .addr_i(ram_addr),
        .wdata_i(ram_wdata),
        .ack_o(ram_ack),
        .last_o(ram_last),
        .rdata_o(ram_rdata),
        .fault_o(ram_fault)
    );
endmodule
