`include "pycore_defs.svh"

// Memory hierarchy shared by pycore_system and pycore_excore_system:
//
//   core dmem  → L1D (8 KB WB+WA)  → xbar dmem  ─┐
//   core imem  → L1I (8 KB RO)     → xbar imem  ─┼─ L2 ─ RAM
//   excore sp  ─────────────────── → xbar excore┘
//
// Excore attaches at L2, never at L1D (memory_system_plan.md §4). The
// flush/invalidate sequencer lives here, next to the ports the grant mux
// in pycore_excore_system.sv waits on: pulse flush_req_i / inv_req_i,
// wait for the matching *_done_o pulse. Single-core ties those off.
// L1I is read-only; it is not flushed on the excore handoff.
module pycore_mem_hier #(
    parameter int    ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter int    IMEM_DATA_W      = PYCORE_IMEM_DATA_WIDTH,
    parameter int    DMEM_DATA_W      = PYCORE_DMEM_DATA_WIDTH,
    parameter string PROG_HEX         = "",
    parameter string CODE_RAM_HEX     = "",
    parameter string DMEM_HEX         = "",
    parameter int    L2_SIZE_BYTES    = PYCORE_L2_SIZE_BYTES,
    parameter int    L2_WAYS          = PYCORE_L2_WAYS,
    parameter int    L2_HIT_CYCLES    = PYCORE_L2_HIT_CYCLES,
    parameter int    L1I_SIZE_BYTES   = PYCORE_L1I_SIZE_BYTES,
    parameter int    L1I_WAYS         = PYCORE_L1I_WAYS,
    parameter int    L1I_HIT_CYCLES   = PYCORE_L1I_HIT_CYCLES,
    parameter int    L1D_SIZE_BYTES   = PYCORE_L1D_SIZE_BYTES,
    parameter int    L1D_WAYS         = PYCORE_L1D_WAYS,
    parameter int    L1D_HIT_CYCLES   = PYCORE_L1D_HIT_CYCLES
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
    output logic [PYCORE_LINE_BYTES*8-1:0] imem_line_o,
    output logic                    imem_line_valid_o,

    input  logic                    dmem_req_i,
    input  logic                    dmem_we_i,
    input  logic                    dmem_line_i,
    input  logic [DMEM_DATA_W/8-1:0] dmem_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   dmem_addr_i,
    input  logic [DMEM_DATA_W-1:0]  dmem_wdata_i,
    input  logic [PYCORE_LINE_BYTES*8-1:0] dmem_wline_i,
    output logic                    dmem_ack_o,
    output logic [DMEM_DATA_W-1:0]  dmem_rdata_o,
    output logic                    dmem_fault_o,

    input  logic                    excore_req_i,
    input  logic                    excore_we_i,
    input  logic [DMEM_DATA_W/8-1:0] excore_wstrb_i,
    input  logic [ADDR_WIDTH-1:0]   excore_addr_i,
    input  logic [DMEM_DATA_W-1:0]  excore_wdata_i,
    output logic                    excore_ack_o,
    output logic [DMEM_DATA_W-1:0]  excore_rdata_o,
    output logic                    excore_fault_o,

    input  logic                    flush_req_i,
    input  logic                    inv_req_i,
    output logic                    flush_done_o,
    output logic                    inv_done_o,
    output logic                    l1d_idle_o,

    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1i_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1i_miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_writeback_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_frame_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l1d_frame_miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] l2_writeback_count_o
);
    logic                   l1d_down_req, l1d_down_we, l1d_down_ack, l1d_down_fault;
    logic [DMEM_DATA_W/8-1:0] l1d_down_wstrb;
    logic [ADDR_WIDTH-1:0]  l1d_down_addr;
    logic [DMEM_DATA_W-1:0] l1d_down_wdata, l1d_down_rdata;

    logic                   l1i_down_req, l1i_down_we, l1i_down_ack, l1i_down_fault;
    logic [IMEM_DATA_W/8-1:0] l1i_down_wstrb;
    logic [ADDR_WIDTH-1:0]  l1i_down_addr;
    logic [IMEM_DATA_W-1:0] l1i_down_wdata, l1i_down_rdata;
    logic [PYCORE_LINE_BYTES*8-1:0] l1i_line;

    logic                   l1d_flush_all, l1d_inv_all;
    logic                   l1d_flush_done, l1d_inv_done, l1d_idle;

    logic                   l2_req, l2_we, l2_ack, l2_fault;
    logic [DMEM_DATA_W/8-1:0] l2_wstrb;
    logic [ADDR_WIDTH-1:0]  l2_addr;
    logic [DMEM_DATA_W-1:0] l2_wdata, l2_rdata;

    logic                   ram_req, ram_we, ram_line, ram_ack, ram_last, ram_fault;
    logic [DMEM_DATA_W/8-1:0] ram_wstrb;
    logic [ADDR_WIDTH-1:0]  ram_addr;
    logic [DMEM_DATA_W-1:0] ram_wdata, ram_rdata;
    logic [PYCORE_LINE_BYTES*8-1:0] ram_wline;

    typedef enum logic [2:0] {
        SQ_IDLE,
        SQ_FLUSH_IDLE,
        SQ_FLUSH_WAIT,
        SQ_INV_IDLE,
        SQ_INV_WAIT
    } seq_e;
    seq_e seq_r;
    logic flush_pend_r;
    logic inv_pend_r;
    logic flush_done_r;
    logic inv_done_r;

    assign l1d_idle_o   = l1d_idle;
    assign flush_done_o = flush_done_r;
    assign inv_done_o   = inv_done_r;
    assign imem_line_o  = l1i_line;
    assign imem_line_valid_o = cache_en_i && imem_ack_o;

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(IMEM_DATA_W),
        .SIZE_BYTES(L1I_SIZE_BYTES),
        .LINE_BYTES(PYCORE_LINE_BYTES),
        .WAYS(L1I_WAYS),
        .READ_ONLY(1'b1),
        .WRITE_BACK(1'b0),
        .HIT_CYCLES(L1I_HIT_CYCLES),
        .DOWN_LINE(1'b0)
    ) l1i (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .cache_en_i(cache_en_i),
        .req_i(imem_req_i),
        .we_i(imem_we_i),
        .wstrb_i(imem_wstrb_i),
        .addr_i(imem_addr_i),
        .wdata_i(imem_wdata_i),
        .line_i(1'b0),
        .wline_i('0),
        .ack_o(imem_ack_o),
        .rdata_o(imem_rdata_o),
        .fault_o(imem_fault_o),
        .rdata_line_o(l1i_line),
        .down_req_o(l1i_down_req),
        .down_we_o(l1i_down_we),
        .down_line_o(),
        .down_wstrb_o(l1i_down_wstrb),
        .down_addr_o(l1i_down_addr),
        .down_wdata_o(l1i_down_wdata),
        .down_wline_o(),
        .down_ack_i(l1i_down_ack),
        .down_last_i(1'b0),
        .down_rdata_i(l1i_down_rdata),
        .down_fault_i(l1i_down_fault),
        .inv_all_i(1'b0),
        .flush_all_i(1'b0),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(),
        .flush_done_o(),
        .idle_o(),
        .hit_count_o(l1i_hit_count_o),
        .miss_count_o(l1i_miss_count_o),
        .writeback_count_o(),
        .region_hit_count_o(),
        .region_miss_count_o()
    );

    pycore_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DMEM_DATA_W),
        .SIZE_BYTES(L1D_SIZE_BYTES),
        .LINE_BYTES(PYCORE_LINE_BYTES),
        .WAYS(L1D_WAYS),
        .READ_ONLY(1'b0),
        .WRITE_BACK(1'b1),
        .HIT_CYCLES(L1D_HIT_CYCLES),
        .DOWN_LINE(1'b0),
        .REGION_BASE(PYCORE_FRAME_STACK_BASE),
        .REGION_LIMIT(PYCORE_FRAME_STACK_BASE + PYCORE_FRAME_STACK_BYTES)
    ) l1d (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .cache_en_i(cache_en_i),
        .req_i(dmem_req_i),
        .we_i(dmem_we_i),
        .wstrb_i(dmem_wstrb_i),
        .addr_i(dmem_addr_i),
        .wdata_i(dmem_wdata_i),
        .line_i(dmem_line_i),
        .wline_i(dmem_wline_i),
        .ack_o(dmem_ack_o),
        .rdata_o(dmem_rdata_o),
        .fault_o(dmem_fault_o),
        .rdata_line_o(),
        .down_req_o(l1d_down_req),
        .down_we_o(l1d_down_we),
        .down_line_o(),
        .down_wstrb_o(l1d_down_wstrb),
        .down_addr_o(l1d_down_addr),
        .down_wdata_o(l1d_down_wdata),
        .down_wline_o(),
        .down_ack_i(l1d_down_ack),
        .down_last_i(1'b0),
        .down_rdata_i(l1d_down_rdata),
        .down_fault_i(l1d_down_fault),
        .inv_all_i(l1d_inv_all),
        .flush_all_i(l1d_flush_all),
        .inv_busy_o(),
        .flush_busy_o(),
        .inv_done_o(l1d_inv_done),
        .flush_done_o(l1d_flush_done),
        .idle_o(l1d_idle),
        .hit_count_o(l1d_hit_count_o),
        .miss_count_o(l1d_miss_count_o),
        .writeback_count_o(l1d_writeback_count_o),
        .region_hit_count_o(l1d_frame_hit_count_o),
        .region_miss_count_o(l1d_frame_miss_count_o)
    );

    pycore_mem_xbar #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .IMEM_DATA_W(IMEM_DATA_W),
        .DMEM_DATA_W(DMEM_DATA_W)
    ) xbar (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .imem_req_i(l1i_down_req),
        .imem_we_i(l1i_down_we),
        .imem_wstrb_i(l1i_down_wstrb),
        .imem_addr_i(l1i_down_addr),
        .imem_wdata_i(l1i_down_wdata),
        .imem_ack_o(l1i_down_ack),
        .imem_rdata_o(l1i_down_rdata),
        .imem_fault_o(l1i_down_fault),
        .dmem_req_i(l1d_down_req),
        .dmem_we_i(l1d_down_we),
        .dmem_wstrb_i(l1d_down_wstrb),
        .dmem_addr_i(l1d_down_addr),
        .dmem_wdata_i(l1d_down_wdata),
        .dmem_ack_o(l1d_down_ack),
        .dmem_rdata_o(l1d_down_rdata),
        .dmem_fault_o(l1d_down_fault),
        .excore_req_i(excore_req_i),
        .excore_we_i(excore_we_i),
        .excore_wstrb_i(excore_wstrb_i),
        .excore_addr_i(excore_addr_i),
        .excore_wdata_i(excore_wdata_i),
        .excore_ack_o(excore_ack_o),
        .excore_rdata_o(excore_rdata_o),
        .excore_fault_o(excore_fault_o),
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
        .line_i(1'b0),
        .wline_i('0),
        .ack_o(l2_ack),
        .rdata_o(l2_rdata),
        .fault_o(l2_fault),
        .rdata_line_o(),
        .down_req_o(ram_req),
        .down_we_o(ram_we),
        .down_line_o(ram_line),
        .down_wstrb_o(ram_wstrb),
        .down_addr_o(ram_addr),
        .down_wdata_o(ram_wdata),
        .down_wline_o(ram_wline),
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
        .idle_o(),
        .hit_count_o(l2_hit_count_o),
        .miss_count_o(l2_miss_count_o),
        .writeback_count_o(l2_writeback_count_o),
        .region_hit_count_o(),
        .region_miss_count_o()
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
        .wline_i(ram_wline),
        .ack_o(ram_ack),
        .last_o(ram_last),
        .rdata_o(ram_rdata),
        .fault_o(ram_fault)
    );

    // Pulse flush_req_i / inv_req_i for one cycle (or hold; pending is
    // captured). *_done_o is a one-cycle pulse when L1D reports done.
    // Do not re-assert flush_all while the cache is scanning: a held
    // flush_all_i on return to IDLE would restart the walk.
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            seq_r        <= SQ_IDLE;
            flush_pend_r <= 1'b0;
            inv_pend_r   <= 1'b0;
            flush_done_r <= 1'b0;
            inv_done_r   <= 1'b0;
            l1d_flush_all <= 1'b0;
            l1d_inv_all   <= 1'b0;
        end else begin
            flush_done_r  <= 1'b0;
            inv_done_r    <= 1'b0;
            l1d_flush_all <= 1'b0;
            l1d_inv_all   <= 1'b0;
            if (flush_req_i)
                flush_pend_r <= 1'b1;
            if (inv_req_i)
                inv_pend_r <= 1'b1;

            unique case (seq_r)
                SQ_IDLE: begin
                    if (flush_pend_r || flush_req_i)
                        seq_r <= SQ_FLUSH_IDLE;
                    else if (inv_pend_r || inv_req_i)
                        seq_r <= SQ_INV_IDLE;
                end
                SQ_FLUSH_IDLE: begin
                    if (l1d_idle) begin
                        l1d_flush_all <= 1'b1;
                        seq_r         <= SQ_FLUSH_WAIT;
                    end
                end
                SQ_FLUSH_WAIT: begin
                    if (l1d_flush_done) begin
                        flush_pend_r <= 1'b0;
                        flush_done_r <= 1'b1;
                        seq_r        <= SQ_IDLE;
                    end
                end
                SQ_INV_IDLE: begin
                    if (l1d_idle) begin
                        l1d_inv_all <= 1'b1;
                        seq_r       <= SQ_INV_WAIT;
                    end
                end
                SQ_INV_WAIT: begin
                    if (l1d_inv_done) begin
                        inv_pend_r <= 1'b0;
                        inv_done_r <= 1'b1;
                        seq_r      <= SQ_IDLE;
                    end
                end
                default: seq_r <= SQ_IDLE;
            endcase
        end
    end
endmodule
