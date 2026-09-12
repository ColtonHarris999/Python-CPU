`include "pycore_defs.svh"

// Generic set-associative cache. One module, three instantiations (L1I,
// L1D, L2). Preserves the §0 req/ack contract:
//   * A request is captured the cycle `req_i` is high (master need not hold).
//   * `ack_o` pulses one cycle when the response is ready, any latency later.
//   * `fault_o` accompanies `ack_o`.
//   * At most one outstanding request per master port.
//
// `cache_en_i=0` is a combinational pass-through to `down_*` (no extra
// cycle from this module). That is the bisect switch and the transparency
// test's control arm — keep it working.
module pycore_cache #(
    parameter int    ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH  = PYCORE_DMEM_DATA_WIDTH,
    parameter int    SIZE_BYTES  = PYCORE_L2_SIZE_BYTES,
    parameter int    LINE_BYTES  = PYCORE_LINE_BYTES,
    parameter int    WAYS        = PYCORE_L2_WAYS,
    parameter bit    READ_ONLY   = 1'b0,
    parameter bit    WRITE_BACK  = 1'b1,
    parameter int    HIT_CYCLES  = 1,
    // 1: down port is a 4-beat line burst (L2 → RAM). 0: each beat is a
    // separate word request (L1D → L2, whose CPU port has no line_i).
    parameter bit    DOWN_LINE   = 1'b1,
    parameter logic [31:0] REGION_BASE  = 32'd0,
    parameter logic [31:0] REGION_LIMIT = 32'd0
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,
    input  logic                  cache_en_i,

    input  logic                  req_i,
    input  logic                  we_i,
    input  logic [DATA_WIDTH/8-1:0] wstrb_i,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] wdata_i,
    output logic                  ack_o,
    output logic [DATA_WIDTH-1:0] rdata_o,
    output logic                  fault_o,

    output logic                  down_req_o,
    output logic                  down_we_o,
    output logic                  down_line_o,
    output logic [DATA_WIDTH/8-1:0] down_wstrb_o,
    output logic [ADDR_WIDTH-1:0] down_addr_o,
    output logic [DATA_WIDTH-1:0] down_wdata_o,
    input  logic                  down_ack_i,
    input  logic                  down_last_i,
    input  logic [DATA_WIDTH-1:0] down_rdata_i,
    input  logic                  down_fault_i,

    input  logic                  inv_all_i,
    input  logic                  flush_all_i,
    output logic                  inv_busy_o,
    output logic                  flush_busy_o,
    output logic                  inv_done_o,
    output logic                  flush_done_o,
    output logic                  idle_o,

    output logic [PYCORE_PERF_CNT_WIDTH-1:0] hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] writeback_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] region_hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] region_miss_count_o
);
    localparam int OFFSET_W        = $clog2(LINE_BYTES);
    localparam int SETS            = SIZE_BYTES / (LINE_BYTES * WAYS);
    localparam int SET_BITS        = $clog2(SETS); // 0 when SETS==1
    localparam int SET_W           = (SET_BITS == 0) ? 1 : SET_BITS;
    localparam int TAG_W           = ADDR_WIDTH - SET_BITS - OFFSET_W;
    localparam int WAY_W           = $clog2(WAYS);
    localparam int AGE_W           = $clog2(WAYS);
    localparam int AGE_PACK_W      = WAYS * AGE_W;
    localparam int WORD_BYTES      = DATA_WIDTH / 8;
    localparam int WORD_SHIFT      = $clog2(WORD_BYTES);
    localparam int BEATS           = LINE_BYTES / WORD_BYTES;
    localparam int BEAT_W          = $clog2(BEATS);
    localparam int LINE_W          = LINE_BYTES * 8;
    localparam int WORD_SEL_W      = OFFSET_W - WORD_SHIFT;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_HIT_WAIT,
        ST_RESPOND,
        ST_WB_ISSUE,
        ST_WB_WAIT,
        ST_FILL_ISSUE,
        ST_FILL_WAIT,
        ST_WT_ISSUE,
        ST_WT_WAIT,
        ST_FAULT,
        ST_FLUSH_SCAN,
        ST_FLUSH_WB_ISSUE,
        ST_FLUSH_WB_WAIT,
        ST_INV
    } state_e;

    state_e state_r;

    logic                valid_q  [0:SETS-1][0:WAYS-1];
    logic                dirty_q  [0:SETS-1][0:WAYS-1];
    logic [TAG_W-1:0]    tag_q    [0:SETS-1][0:WAYS-1];
    logic [LINE_W-1:0]   data_q   [0:SETS-1][0:WAYS-1];
    logic [AGE_PACK_W-1:0] ages_q [0:SETS-1];

    logic                   cap_we_r;
    logic [DATA_WIDTH/8-1:0] cap_wstrb_r;
    logic [ADDR_WIDTH-1:0]  cap_addr_r;
    logic [DATA_WIDTH-1:0]  cap_wdata_r;
    logic [WAY_W-1:0]       cap_way_r;
    logic [LINE_W-1:0]      cap_line_r;
    logic [BEAT_W-1:0]      beat_r;
    logic [ADDR_WIDTH-1:0]  wb_addr_r;
    logic [LINE_W-1:0]      wb_line_r;
    int                     hit_wait_r;

    logic [SET_W-1:0]       flush_set_r;
    logic [WAY_W-1:0]       flush_way_r;

    logic                   ack_r;
    logic                   fault_r;
    logic [DATA_WIDTH-1:0]  rdata_r;
    logic                   down_req_r;
    logic                   down_we_r;
    logic                   down_line_r;
    logic [DATA_WIDTH/8-1:0] down_wstrb_r;
    logic [ADDR_WIDTH-1:0]  down_addr_r;

    logic [PYCORE_PERF_CNT_WIDTH-1:0] hit_count_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] miss_count_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] writeback_count_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] region_hit_count_r;
    logic [PYCORE_PERF_CNT_WIDTH-1:0] region_miss_count_r;
    logic                   inv_done_r;
    logic                   flush_done_r;

    logic [SET_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;
    logic [WORD_SEL_W-1:0] req_word;
    logic             comb_hit;
    logic [WAY_W-1:0] comb_hit_way;
    logic [WAY_W-1:0] comb_free_way;
    logic             comb_have_free;
    logic [WAY_W-1:0] lru_victim;
    logic [AGE_PACK_W-1:0] lru_ages_next;
    logic [WAY_W-1:0] victim_way;

    logic [SET_W-1:0] cap_set;
    logic [TAG_W-1:0] cap_tag;
    logic [WORD_SEL_W-1:0] cap_word;

    function automatic logic [ADDR_WIDTH-1:0] line_align(
        input logic [ADDR_WIDTH-1:0] a
    );
        line_align = {a[ADDR_WIDTH-1:OFFSET_W], {OFFSET_W{1'b0}}};
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] make_addr(
        input logic [TAG_W-1:0] tag,
        input logic [SET_W-1:0] set
    );
        if (SETS == 1)
            make_addr = {tag, {OFFSET_W{1'b0}}};
        else
            make_addr = {tag, set[SET_BITS-1:0], {OFFSET_W{1'b0}}};
    endfunction

    function automatic logic [DATA_WIDTH-1:0] line_word(
        input logic [LINE_W-1:0] line,
        input logic [WORD_SEL_W-1:0] word
    );
        line_word = line[word*DATA_WIDTH +: DATA_WIDTH];
    endfunction

    function automatic logic [LINE_W-1:0] merge_word(
        input logic [LINE_W-1:0] line,
        input logic [WORD_SEL_W-1:0] word,
        input logic [DATA_WIDTH-1:0] data,
        input logic [DATA_WIDTH/8-1:0] strb
    );
        logic [LINE_W-1:0] out;
        logic [DATA_WIDTH-1:0] merged;
        out = line;
        merged = line[word*DATA_WIDTH +: DATA_WIDTH];
        for (int b = 0; b < DATA_WIDTH/8; b++) begin
            if (strb[b])
                merged[8*b +: 8] = data[8*b +: 8];
        end
        out[word*DATA_WIDTH +: DATA_WIDTH] = merged;
        merge_word = out;
    endfunction

    generate
        if (SETS == 1) begin : g_one_set
            assign req_set  = '0;
            assign req_tag  = addr_i[OFFSET_W +: TAG_W];
            assign cap_set  = '0;
            assign cap_tag  = cap_addr_r[OFFSET_W +: TAG_W];
        end else begin : g_many_sets
            assign req_set  = addr_i[OFFSET_W +: SET_BITS];
            assign req_tag  = addr_i[OFFSET_W + SET_BITS +: TAG_W];
            assign cap_set  = cap_addr_r[OFFSET_W +: SET_BITS];
            assign cap_tag  = cap_addr_r[OFFSET_W + SET_BITS +: TAG_W];
        end
    endgenerate
    assign req_word = addr_i[WORD_SHIFT +: WORD_SEL_W];
    assign cap_word = cap_addr_r[WORD_SHIFT +: WORD_SEL_W];

    always_comb begin
        comb_hit      = 1'b0;
        comb_hit_way  = '0;
        comb_have_free = 1'b0;
        comb_free_way = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[req_set][w] && tag_q[req_set][w] == req_tag) begin
                comb_hit     = 1'b1;
                comb_hit_way = w[WAY_W-1:0];
            end
            if (!valid_q[req_set][w] && !comb_have_free) begin
                comb_have_free = 1'b1;
                comb_free_way  = w[WAY_W-1:0];
            end
        end
    end

    // Touch way is only consumed when ages_q is written (hit in IDLE, fill
    // install). Do not feed lru_victim back into touch_way: that is a
    // combinational loop (victim depends only on ages_i, but Verilator still
    // reports UNOPTFLAT).
    pycore_cache_lru #(.WAYS(WAYS)) u_lru (
        .ages_i(ages_q[(state_r == ST_IDLE) ? req_set : cap_set]),
        .touch_way_i((state_r == ST_IDLE)
                         ? (comb_hit ? comb_hit_way : '0)
                         : cap_way_r),
        .ages_o(lru_ages_next),
        .victim_o(lru_victim)
    );

    always_comb begin
        victim_way = comb_have_free ? comb_free_way : lru_victim;
    end

    // --- CPU-facing and down-facing mux (CACHE_EN=0 is combinational) -----
    assign ack_o   = cache_en_i ? ack_r   : down_ack_i;
    assign rdata_o = cache_en_i ? rdata_r : down_rdata_i;
    assign fault_o = cache_en_i ? fault_r : down_fault_i;

    assign down_req_o   = cache_en_i ? down_req_r : req_i;
    assign down_we_o    = cache_en_i ? down_we_r  : we_i;
    assign down_line_o  = cache_en_i ? down_line_r : 1'b0;
    assign down_wstrb_o = cache_en_i ? down_wstrb_r : wstrb_i;
    assign down_addr_o  = cache_en_i ? down_addr_r
                                     : {addr_i[ADDR_WIDTH-1:WORD_SHIFT], {WORD_SHIFT{1'b0}}};
    assign down_wdata_o = cache_en_i
                        ? ((state_r == ST_WB_WAIT || state_r == ST_WB_ISSUE ||
                            state_r == ST_FLUSH_WB_WAIT || state_r == ST_FLUSH_WB_ISSUE)
                               ? line_word(wb_line_r, beat_r)
                               : cap_wdata_r)
                        : wdata_i;

    assign hit_count_o       = hit_count_r;
    assign miss_count_o      = miss_count_r;
    assign writeback_count_o = writeback_count_r;
    assign region_hit_count_o  = region_hit_count_r;
    assign region_miss_count_o = region_miss_count_r;
    assign idle_o            = (state_r == ST_IDLE);
    assign inv_busy_o        = (state_r == ST_INV);
    assign flush_busy_o      = (state_r == ST_FLUSH_SCAN) ||
                               (state_r == ST_FLUSH_WB_ISSUE) ||
                               (state_r == ST_FLUSH_WB_WAIT);
    assign inv_done_o        = inv_done_r;
    assign flush_done_o      = flush_done_r;

    wire req_in_region = (REGION_LIMIT != 32'd0) &&
                         (addr_i >= ADDR_WIDTH'(REGION_BASE)) &&
                         (addr_i <  ADDR_WIDTH'(REGION_LIMIT));
    wire down_beat_last = DOWN_LINE ? down_last_i
                                    : (beat_r == BEAT_W'(BEATS - 1));
    wire [ADDR_WIDTH-1:0] down_fill_addr =
        line_align(cap_addr_r) + (DOWN_LINE ? '0
                                            : (ADDR_WIDTH'(beat_r) << WORD_SHIFT));
    wire [ADDR_WIDTH-1:0] down_wb_addr =
        wb_addr_r + (DOWN_LINE ? '0 : (ADDR_WIDTH'(beat_r) << WORD_SHIFT));

    int hit_cycles_eff;
    always_comb begin
        hit_cycles_eff = (HIT_CYCLES < 1) ? 1 : HIT_CYCLES;
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r     <= ST_IDLE;
            cap_we_r    <= 1'b0;
            cap_wstrb_r <= '0;
            cap_addr_r  <= '0;
            cap_wdata_r <= '0;
            cap_way_r   <= '0;
            cap_line_r  <= '0;
            beat_r      <= '0;
            wb_addr_r   <= '0;
            wb_line_r   <= '0;
            hit_wait_r  <= 0;
            flush_set_r <= '0;
            flush_way_r <= '0;
            ack_r       <= 1'b0;
            fault_r     <= 1'b0;
            rdata_r     <= '0;
            down_req_r  <= 1'b0;
            down_we_r   <= 1'b0;
            down_line_r <= 1'b0;
            down_wstrb_r <= '0;
            down_addr_r <= '0;
            hit_count_r <= '0;
            miss_count_r <= '0;
            writeback_count_r <= '0;
            region_hit_count_r  <= '0;
            region_miss_count_r <= '0;
            inv_done_r  <= 1'b0;
            flush_done_r <= 1'b0;
            for (int s = 0; s < SETS; s++) begin
                ages_q[s] <= '0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_q[s][w] <= 1'b0;
                    dirty_q[s][w] <= 1'b0;
                    tag_q[s][w]   <= '0;
                    data_q[s][w]  <= '0;
                    ages_q[s][w*AGE_W +: AGE_W] <= AGE_W'(w);
                end
            end
        end else begin
            ack_r        <= 1'b0;
            fault_r      <= 1'b0;
            down_req_r   <= 1'b0;
            inv_done_r   <= 1'b0;
            flush_done_r <= 1'b0;

            if (!cache_en_i) begin
                state_r <= ST_IDLE;
                if (flush_all_i)
                    flush_done_r <= 1'b1;
                if (inv_all_i)
                    inv_done_r <= 1'b1;
            end else unique case (state_r)
                ST_IDLE: begin
                    if (inv_all_i) begin
                        state_r <= ST_INV;
                    end else if (flush_all_i) begin
                        flush_set_r <= '0;
                        flush_way_r <= '0;
                        state_r     <= ST_FLUSH_SCAN;
                    end else if (req_i) begin
                        cap_we_r    <= we_i;
                        cap_wstrb_r <= wstrb_i;
                        cap_addr_r  <= addr_i;
                        cap_wdata_r <= wdata_i;
                        if (we_i && READ_ONLY) begin
                            ack_r   <= 1'b1;
                            fault_r <= 1'b1;
                            rdata_r <= '0;
                        end else if (comb_hit) begin
                            cap_way_r          <= comb_hit_way;
                            ages_q[req_set]    <= lru_ages_next;
                            hit_count_r        <= hit_count_r + 1'b1;
                            if (req_in_region)
                                region_hit_count_r <= region_hit_count_r + 1'b1;
                            if (we_i) begin
                                data_q[req_set][comb_hit_way] <=
                                    merge_word(data_q[req_set][comb_hit_way],
                                               req_word, wdata_i, wstrb_i);
                                dirty_q[req_set][comb_hit_way] <= 1'b1;
                            end
                            if (hit_cycles_eff <= 1) begin
                                ack_r   <= 1'b1;
                                rdata_r <= line_word(data_q[req_set][comb_hit_way],
                                                     req_word);
                            end else begin
                                hit_wait_r <= hit_cycles_eff - 1;
                                state_r    <= ST_HIT_WAIT;
                            end
                        end else begin
                            miss_count_r <= miss_count_r + 1'b1;
                            if (req_in_region)
                                region_miss_count_r <= region_miss_count_r + 1'b1;
                            cap_way_r    <= victim_way;
                            if (we_i && !WRITE_BACK) begin
                                state_r <= ST_WT_ISSUE;
                            end else if (valid_q[req_set][victim_way] &&
                                         dirty_q[req_set][victim_way] &&
                                         WRITE_BACK) begin
                                wb_addr_r <= make_addr(tag_q[req_set][victim_way],
                                                       req_set);
                                wb_line_r <= data_q[req_set][victim_way];
                                beat_r    <= '0;
                                state_r   <= ST_WB_ISSUE;
                            end else begin
                                beat_r  <= '0;
                                cap_line_r <= '0;
                                state_r <= ST_FILL_ISSUE;
                            end
                        end
                    end
                end
                ST_HIT_WAIT: begin
                    if (hit_wait_r <= 1)
                        state_r <= ST_RESPOND;
                    else
                        hit_wait_r <= hit_wait_r - 1;
                end
                ST_RESPOND: begin
                    ack_r   <= 1'b1;
                    fault_r <= 1'b0;
                    rdata_r <= line_word(data_q[cap_set][cap_way_r], cap_word);
                    state_r <= ST_IDLE;
                end
                ST_FAULT: begin
                    ack_r   <= 1'b1;
                    fault_r <= 1'b1;
                    rdata_r <= '0;
                    state_r <= ST_IDLE;
                end
                ST_WB_ISSUE: begin
                    down_req_r   <= 1'b1;
                    down_we_r    <= 1'b1;
                    down_line_r  <= DOWN_LINE;
                    down_wstrb_r <= {DATA_WIDTH/8{1'b1}};
                    down_addr_r  <= down_wb_addr;
                    if (beat_r == '0)
                        writeback_count_r <= writeback_count_r + 1'b1;
                    state_r      <= ST_WB_WAIT;
                end
                ST_WB_WAIT: begin
                    if (down_ack_i) begin
                        if (down_fault_i) begin
                            state_r <= ST_FAULT;
                        end else if (down_beat_last) begin
                            beat_r     <= '0;
                            cap_line_r <= '0;
                            state_r    <= ST_FILL_ISSUE;
                        end else begin
                            beat_r <= beat_r + BEAT_W'(1);
                            if (!DOWN_LINE)
                                state_r <= ST_WB_ISSUE;
                        end
                    end
                end
                ST_FILL_ISSUE: begin
                    down_req_r   <= 1'b1;
                    down_we_r    <= 1'b0;
                    down_line_r  <= DOWN_LINE;
                    down_wstrb_r <= '0;
                    down_addr_r  <= down_fill_addr;
                    state_r      <= ST_FILL_WAIT;
                end
                ST_FILL_WAIT: begin
                    if (down_ack_i) begin
                        if (down_fault_i) begin
                            state_r <= ST_FAULT;
                        end else begin
                            cap_line_r[beat_r*DATA_WIDTH +: DATA_WIDTH] <= down_rdata_i;
                            if (down_beat_last) begin
                                logic [LINE_W-1:0] installed;
                                installed = cap_line_r;
                                installed[beat_r*DATA_WIDTH +: DATA_WIDTH] = down_rdata_i;
                                if (cap_we_r)
                                    installed = merge_word(installed, cap_word,
                                                           cap_wdata_r, cap_wstrb_r);
                                data_q[cap_set][cap_way_r]  <= installed;
                                tag_q[cap_set][cap_way_r]   <= cap_tag;
                                valid_q[cap_set][cap_way_r] <= 1'b1;
                                dirty_q[cap_set][cap_way_r] <= cap_we_r;
                                ages_q[cap_set]             <= lru_ages_next;
                                cap_line_r                  <= installed;
                                ack_r                       <= 1'b1;
                                rdata_r <= line_word(installed, cap_word);
                                state_r                     <= ST_IDLE;
                            end else begin
                                beat_r <= beat_r + BEAT_W'(1);
                                if (!DOWN_LINE)
                                    state_r <= ST_FILL_ISSUE;
                            end
                        end
                    end
                end
                ST_WT_ISSUE: begin
                    down_req_r   <= 1'b1;
                    down_we_r    <= 1'b1;
                    down_line_r  <= 1'b0;
                    down_wstrb_r <= cap_wstrb_r;
                    down_addr_r  <= cap_addr_r;
                    state_r      <= ST_WT_WAIT;
                end
                ST_WT_WAIT: begin
                    if (down_ack_i) begin
                        if (down_fault_i)
                            state_r <= ST_FAULT;
                        else begin
                            ack_r   <= 1'b1;
                            rdata_r <= '0;
                            state_r <= ST_IDLE;
                        end
                    end
                end
                ST_FLUSH_SCAN: begin
                    if (valid_q[flush_set_r][flush_way_r] &&
                        dirty_q[flush_set_r][flush_way_r] && WRITE_BACK) begin
                        wb_addr_r <= make_addr(tag_q[flush_set_r][flush_way_r],
                                               flush_set_r);
                        wb_line_r <= data_q[flush_set_r][flush_way_r];
                        beat_r    <= '0;
                        state_r   <= ST_FLUSH_WB_ISSUE;
                    end else begin
                        valid_q[flush_set_r][flush_way_r] <= 1'b0;
                        dirty_q[flush_set_r][flush_way_r] <= 1'b0;
                        if (flush_way_r == WAY_W'(WAYS - 1)) begin
                            if ((SETS == 1) || (flush_set_r == SET_W'(SETS - 1))) begin
                                flush_done_r <= 1'b1;
                                state_r      <= ST_IDLE;
                            end else begin
                                flush_set_r <= flush_set_r + SET_W'(1);
                                flush_way_r <= '0;
                            end
                        end else
                            flush_way_r <= flush_way_r + WAY_W'(1);
                    end
                end
                ST_FLUSH_WB_ISSUE: begin
                    down_req_r   <= 1'b1;
                    down_we_r    <= 1'b1;
                    down_line_r  <= DOWN_LINE;
                    down_wstrb_r <= {DATA_WIDTH/8{1'b1}};
                    down_addr_r  <= down_wb_addr;
                    if (beat_r == '0)
                        writeback_count_r <= writeback_count_r + 1'b1;
                    state_r      <= ST_FLUSH_WB_WAIT;
                end
                ST_FLUSH_WB_WAIT: begin
                    if (down_ack_i) begin
                        if (down_fault_i) begin
                            valid_q[flush_set_r][flush_way_r] <= 1'b0;
                            dirty_q[flush_set_r][flush_way_r] <= 1'b0;
                            state_r <= ST_FLUSH_SCAN;
                        end else if (down_beat_last) begin
                            valid_q[flush_set_r][flush_way_r] <= 1'b0;
                            dirty_q[flush_set_r][flush_way_r] <= 1'b0;
                            state_r <= ST_FLUSH_SCAN;
                            if (flush_way_r == WAY_W'(WAYS - 1)) begin
                                if ((SETS == 1) ||
                                    (flush_set_r == SET_W'(SETS - 1))) begin
                                    flush_done_r <= 1'b1;
                                    state_r      <= ST_IDLE;
                                end else begin
                                    flush_set_r <= flush_set_r + SET_W'(1);
                                    flush_way_r <= '0;
                                    state_r     <= ST_FLUSH_SCAN;
                                end
                            end else
                                flush_way_r <= flush_way_r + WAY_W'(1);
                        end else begin
                            beat_r <= beat_r + BEAT_W'(1);
                            if (!DOWN_LINE)
                                state_r <= ST_FLUSH_WB_ISSUE;
                        end
                    end
                end
                ST_INV: begin
                    for (int s = 0; s < SETS; s++) begin
                        for (int w = 0; w < WAYS; w++) begin
                            valid_q[s][w] <= 1'b0;
                            dirty_q[s][w] <= 1'b0;
                        end
                    end
                    inv_done_r <= 1'b1;
                    state_r    <= ST_IDLE;
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end
endmodule
