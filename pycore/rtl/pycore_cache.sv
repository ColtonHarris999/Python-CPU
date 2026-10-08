`include "pycore_defs.svh"

// Generic set-associative cache. One module, three instantiations (L1I,
// L1D, L2). Preserves the §0 req/ack contract:
//   * A request is captured the cycle `req_i` is high (master need not hold).
//   * `ack_o` pulses one cycle when the response is ready, any latency later.
//   * `fault_o` accompanies `ack_o`.
//   * At most one outstanding request per master port.
// Two opt-in additions leave that contract alone for everyone else: PIPE
// (L2: pipelined line requests, in order) and NB (L1D: non-blocking line
// reads with up to NB_SLOTS fills in flight). See memory_hierarchy.md,
// "Several loads in flight".
//
// The two faces speak different protocols on purpose: the CPU port is the
// §0 word req/ack used by every master; the down port adds `down_line_o` /
// `down_last_i` / `down_wline_o` for L2→RAM line bursts. L1 instantiations
// set DOWN_LINE=0 and issue one word at a time into the L2 CPU port (no
// `line_i` there). `rdata_line_o` is a sideband on the CPU port: the full
// line of the responding way, valid with `ack_o`. Fetch captures it into
// the P4b line register. L1D/L2 leave it unconnected.
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
    // L1I: write-invalidate, no-allocate. On we_i, drop a hit line if
    // present and forward the write downstream (ST_WT_*). Do not merge
    // the written word into the cache. Orthogonal to READ_ONLY, which
    // still faults writes when this is 0.
    parameter bit    WRITE_INV_NO_ALLOC = 1'b0,
    parameter bit    WRITE_BACK  = 1'b1,
    // L1D only: an all-zero full-line write is allocator initialization.
    // Forward it as one full-line request without displacing an L1 line.
    parameter bit    ZERO_LINE_BYPASS = 1'b0,
    parameter int    HIT_CYCLES  = 1,
    // L2 sets this so +L2_HIT=N overrides HIT_CYCLES. Other caches ignore it.
    parameter bit    HIT_PLUSARG = 1'b0,
    // 1: down port is a 4-beat line burst (L2 → RAM). 0: each beat is a
    // separate word request (L1D → L2, whose CPU port has no line_i).
    parameter bit    DOWN_LINE   = 1'b1,
    parameter logic [31:0] REGION_BASE  = 32'd0,
    parameter logic [31:0] REGION_LIMIT = 32'd0,
    // L2: accept pipelined line requests (pipe_i) back to back while they
    // hit; responses return in order (see "Pipelined port" below).
    parameter bit    PIPE        = 1'b0,
    // L1D: non-blocking line-read port (nb_*) with NB_SLOTS fills in flight
    // on a pipelined down port (see "Non-blocking port" below).
    parameter bit    NB          = 1'b0,
    parameter int    NB_SLOTS    = 4,
    parameter int    PQ_DEPTH    = 4
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,
    input  logic                  cache_en_i,

    input  logic                  req_i,
    input  logic                  we_i,
    input  logic [DATA_WIDTH/8-1:0] wstrb_i,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] wdata_i,
    // Full-line write (P5c): when `line_i` and `we_i`, install `wline_i`
    // without a fill. STRACC uses this so a freshly allocated result line
    // is not filled from memory only to be overwritten.
    input  logic                  line_i,
    input  logic [LINE_BYTES*8-1:0] wline_i,
    output logic                  ack_o,
    output logic [DATA_WIDTH-1:0] rdata_o,
    output logic                  fault_o,
    // Full line of the responding way, valid with ack_o when cache_en_i.
    // CACHE_EN=0 pass-through has no line; drives 0 so fetch will not fill
    // its buffer from a single-word bypass response.
    output logic [LINE_BYTES*8-1:0] rdata_line_o,
    // Pipelined requests (PIPE): a line read (we_i=0) or line write (we_i=1,
    // line_i=1) with pipe_i set is accepted when gnt_o is high in the same
    // cycle; the master holds it until then. A read answers with BEATS acks
    // (last_o on the final one), a write with one. A fault answers with one
    // ack carrying fault_o and last_o. Ordinary requests: last_o is high with
    // every ack.
    input  logic                  pipe_i,
    output logic                  gnt_o,
    output logic                  last_o,

    // Non-blocking line reads (NB). A request is accepted when nb_gnt_o is
    // high in the same cycle. nb_pf_i marks a prefetch: it only fills the
    // cache and never answers. Other reads answer once, in any order, with
    // nb_ack_o, their nb_id_o and the whole line.
    input  logic                  nb_req_i,
    input  logic                  nb_pf_i,
    input  logic [ADDR_WIDTH-1:0] nb_addr_i,
    input  logic [3:0]            nb_id_i,
    output logic                  nb_gnt_o,
    output logic                  nb_ack_o,
    output logic                  nb_fault_o,
    output logic [3:0]            nb_id_o,
    output logic [LINE_BYTES*8-1:0] nb_line_o,

    output logic                  down_req_o,
    // NB: the down request is a pipelined line request, held until
    // down_gnt_i (the next level must be PIPE).
    output logic                  down_pipe_o,
    input  logic                  down_gnt_i,
    output logic                  down_we_o,
    output logic                  down_line_o,
    output logic [DATA_WIDTH/8-1:0] down_wstrb_o,
    output logic [ADDR_WIDTH-1:0] down_addr_o,
    output logic [DATA_WIDTH-1:0] down_wdata_o,
    // Whole dirty line for DOWN_LINE writeback. RAM indexes it with its
    // own beat counter so the two FSMs cannot drift (word 0 twice / word
    // 3 never). Master need not hold this after the captured req cycle.
    output logic [LINE_BYTES*8-1:0] down_wline_o,
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

    typedef enum logic [4:0] {
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
        ST_INV,
        ST_ZL_ISSUE,
        ST_ZL_WAIT,
        ST_PMISS,       // pipelined miss: choose the victim in cap_set
        ST_PINST        // pipelined line-write miss, clean victim: install
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
    logic                   cap_line_wr_r;
    logic [LINE_W-1:0]      cap_wline_r;
    logic [BEAT_W-1:0]      beat_r;
    logic [ADDR_WIDTH-1:0]  wb_addr_r;
    logic [LINE_W-1:0]      wb_line_r;
    int                     hit_wait_r;

    logic [SET_W-1:0]       flush_set_r;
    logic [WAY_W-1:0]       flush_way_r;

    logic                   ack_r;
    logic                   fault_r;
    logic [DATA_WIDTH-1:0]  rdata_r;
    logic [LINE_W-1:0]      rline_r;
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

    // ---- Pipelined port (PIPE) -----------------------------------------
    // A pipelined hit reads (or writes) the line when it is accepted and
    // queues its response, due HIT_CYCLES later; the queue answers in order,
    // so an isolated request takes exactly as long as an ordinary one. A
    // pipelined miss stops acceptance, waits for the queue to drain, then
    // runs the ordinary miss path and queues its response. Ordinary requests
    // are taken only while the queue is empty.
    localparam int PQ_W = (PQ_DEPTH <= 1) ? 1 : $clog2(PQ_DEPTH);
    logic              pq_rd_q    [0:PQ_DEPTH-1];   // read (BEATS acks) or write (one)
    logic              pq_fault_q [0:PQ_DEPTH-1];
    logic [LINE_W-1:0] pq_line_q  [0:PQ_DEPTH-1];
    logic [31:0]       pq_at_q    [0:PQ_DEPTH-1];   // first ack no earlier than this cycle
    logic [PQ_W-1:0]   pq_head_r;
    logic [PQ_W:0]     pq_cnt_r;
    logic [BEAT_W-1:0] pq_beat_r;
    logic [31:0]       cyc_r;
    logic              pmiss_r;      // a pipelined miss waits in cap_*
    logic              cap_pipe_r;   // the miss path is serving a pipelined request
    logic              last_r;
    logic              pipe_ok, pipe_take;
    assign pipe_ok   = PIPE && cache_en_i && (state_r == ST_IDLE) && !pmiss_r &&
                       (pq_cnt_r < (PQ_W+1)'(PQ_DEPTH)) && !inv_all_i && !flush_all_i;
    assign pipe_take = pipe_ok && req_i && pipe_i;

    // Ordinary request held for later (NB). Masters may pulse req_i for
    // one cycle and expect it captured; an ordinary miss that arrives while
    // non-blocking fills are in flight waits here, ahead of new
    // non-blocking requests, until the port drains. c_* is the request the
    // ordinary path sees: the held one, else the port.
    logic                    lp_v_r, lp_we_r, lp_line_r, lp_cap;
    logic [DATA_WIDTH/8-1:0] lp_wstrb_r;
    logic [ADDR_WIDTH-1:0]   lp_addr_r;
    logic [DATA_WIDTH-1:0]   lp_wdata_r;
    logic [LINE_W-1:0]       lp_wline_r;
    logic                    c_req, c_we, c_line;
    logic [DATA_WIDTH/8-1:0] c_wstrb;
    logic [ADDR_WIDTH-1:0]   c_addr;
    logic [DATA_WIDTH-1:0]   c_wdata;
    logic [LINE_W-1:0]       c_wline;
    assign c_req   = lp_v_r || req_i;
    assign c_we    = lp_v_r ? lp_we_r    : we_i;
    assign c_line  = lp_v_r ? lp_line_r  : line_i;
    assign c_wstrb = lp_v_r ? lp_wstrb_r : wstrb_i;
    assign c_addr  = lp_v_r ? lp_addr_r  : addr_i;
    assign c_wdata = lp_v_r ? lp_wdata_r : wdata_i;
    assign c_wline = lp_v_r ? lp_wline_r : wline_i;

    // Free way in cap_set (the pipelined miss picks its victim after the
    // queue drains, when addr_i no longer names the set).
    logic             cap_have_free;
    logic [WAY_W-1:0] cap_free_way;

    // ---- Non-blocking port (NB) ----------------------------------------
    // Up to NB_SLOTS line fills in flight. Slots issue in order on the
    // pipelined down port and fill in order (the next level answers in
    // order); the oldest filled slot installs, choosing its victim then. A
    // dirty victim goes to a one-line writeback buffer that issues ahead of
    // further reads. Ordinary requests that hit are served while fills are
    // in flight; an ordinary miss waits until the port is drained, so the
    // ordinary miss path always owns the down port alone.
    localparam int NS_W = (NB_SLOTS <= 1) ? 1 : $clog2(NB_SLOTS);
    localparam int RQ_DEPTH = 2 * NB_SLOTS;   // powers of two: indices wrap
    localparam int RQ_W = $clog2(RQ_DEPTH);
    localparam int DQ_DEPTH = 2 * NB_SLOTS;
    localparam int DQ_W = $clog2(DQ_DEPTH);
    logic [ADDR_WIDTH-1:0] ms_addr_q  [0:NB_SLOTS-1];   // line address
    logic [3:0]            ms_id_q    [0:NB_SLOTS-1];
    logic                  ms_pf_q    [0:NB_SLOTS-1];
    logic                  ms_fault_q [0:NB_SLOTS-1];
    logic [LINE_W-1:0]     ms_line_q  [0:NB_SLOTS-1];
    logic [NS_W-1:0]       ms_head_r;                    // oldest slot
    logic [NS_W:0]         ms_cnt_r;                     // slots in use
    logic [NS_W:0]         ms_iss_r;                     // slots issued (from head)
    logic [NS_W:0]         ms_done_r;                    // slots filled (from head)
    logic [BEAT_W-1:0]     ms_beat_r;                    // beat of the filling slot
    logic                  wbb_v_r, wbb_iss_r;
    logic [ADDR_WIDTH-1:0] wbb_addr_r;
    logic [LINE_W-1:0]     wbb_line_r;
    logic                  dq_wr_q [0:DQ_DEPTH-1];       // outstanding down ops
    logic [DQ_W-1:0]       dq_head_r;
    logic [DQ_W:0]         dq_cnt_r;
    logic [3:0]            rq_id_q    [0:RQ_DEPTH-1];    // responses
    logic                  rq_fault_q [0:RQ_DEPTH-1];
    logic [LINE_W-1:0]     rq_line_q  [0:RQ_DEPTH-1];
    logic [RQ_W-1:0]       rq_head_r;
    logic [RQ_W:0]         rq_cnt_r;

    logic                  nb_busy;
    assign nb_busy = NB && ((ms_cnt_r != '0) || wbb_v_r || (dq_cnt_r != '0));

    // Request lookup.
    logic [SET_W-1:0]      nb_set;
    logic [TAG_W-1:0]      nb_tag;
    logic [ADDR_WIDTH-1:0] nb_laddr;
    logic                  nb_hit, nb_inflight, nb_wbconf;
    logic [WAY_W-1:0]      nb_hit_way;
    logic [AGE_PACK_W-1:0] nb_ages_next;
    // Install of the oldest slot.
    logic [NS_W-1:0]       ins_slot;
    logic [SET_W-1:0]      ins_set;
    logic [TAG_W-1:0]      ins_tag;
    logic                  ins_have_free;
    logic [WAY_W-1:0]      ins_free_way, ins_lru_victim, ins_way;
    logic [AGE_PACK_W-1:0] ins_ages_next;
    logic                  ins_ready, ins_now, ins_dirty_victim;
    // Down request.
    logic                  nbd_req, nbd_we;
    logic [ADDR_WIDTH-1:0] nbd_addr;
    logic [NS_W-1:0]       iss_slot;
    // Ordinary request taken this cycle in ST_IDLE.
    logic                  leg_hit_ok, leg_take, nb_take, rq_room;

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
            assign req_tag  = c_addr[OFFSET_W +: TAG_W];
            assign cap_set  = '0;
            assign cap_tag  = cap_addr_r[OFFSET_W +: TAG_W];
        end else begin : g_many_sets
            assign req_set  = c_addr[OFFSET_W +: SET_BITS];
            assign req_tag  = c_addr[OFFSET_W + SET_BITS +: TAG_W];
            assign cap_set  = cap_addr_r[OFFSET_W +: SET_BITS];
            assign cap_tag  = cap_addr_r[OFFSET_W + SET_BITS +: TAG_W];
        end
    endgenerate
    assign req_word = c_addr[WORD_SHIFT +: WORD_SEL_W];
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

    int hit_cycles_eff;
    int hit_plus_sim;
    initial begin
        hit_plus_sim = 0;
        if (HIT_PLUSARG)
            void'($value$plusargs("L2_HIT=%d", hit_plus_sim));
    end
    always_comb begin
        if (hit_plus_sim > 0)
            hit_cycles_eff = hit_plus_sim;
        else
            hit_cycles_eff = (HIT_CYCLES < 1) ? 1 : HIT_CYCLES;
    end

    always_comb begin
        cap_have_free = 1'b0;
        cap_free_way  = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (!valid_q[cap_set][w] && !cap_have_free) begin
                cap_have_free = 1'b1;
                cap_free_way  = w[WAY_W-1:0];
            end
        end
    end

    // ---- Non-blocking port: lookup, install choice, down request --------
    generate
        if (SETS == 1) begin : g_nb_one_set
            assign nb_set  = '0;
            assign nb_tag  = nb_addr_i[OFFSET_W +: TAG_W];
            assign ins_set = '0;
            assign ins_tag = ms_addr_q[ins_slot][OFFSET_W +: TAG_W];
        end else begin : g_nb_many_sets
            assign nb_set  = nb_addr_i[OFFSET_W +: SET_BITS];
            assign nb_tag  = nb_addr_i[OFFSET_W + SET_BITS +: TAG_W];
            assign ins_set = ms_addr_q[ins_slot][OFFSET_W +: SET_BITS];
            assign ins_tag = ms_addr_q[ins_slot][OFFSET_W + SET_BITS +: TAG_W];
        end
    endgenerate
    assign nb_laddr = line_align(nb_addr_i);
    assign ins_slot = ms_head_r;
    assign iss_slot = ms_head_r + ms_iss_r[NS_W-1:0];

    always_comb begin
        nb_hit      = 1'b0;
        nb_hit_way  = '0;
        nb_inflight = 1'b0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[nb_set][w] && tag_q[nb_set][w] == nb_tag) begin
                nb_hit     = 1'b1;
                nb_hit_way = w[WAY_W-1:0];
            end
        end
        for (int i = 0; i < NB_SLOTS; i++) begin
            if ((NS_W+1)'(i) < ms_cnt_r &&
                ms_addr_q[NS_W'(ms_head_r + NS_W'(i))] == nb_laddr)
                nb_inflight = 1'b1;
        end
        ins_have_free = 1'b0;
        ins_free_way  = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (!valid_q[ins_set][w] && !ins_have_free) begin
                ins_have_free = 1'b1;
                ins_free_way  = w[WAY_W-1:0];
            end
        end
    end
    assign nb_wbconf = wbb_v_r && (wbb_addr_r == nb_laddr);
    assign ins_way   = ins_have_free ? ins_free_way : ins_lru_victim;
    assign ins_dirty_victim = WRITE_BACK && valid_q[ins_set][ins_way] &&
                              dirty_q[ins_set][ins_way];

    /* verilator lint_off PINCONNECTEMPTY */
    pycore_cache_lru #(.WAYS(WAYS)) u_lru_nb (
        .ages_i(ages_q[nb_set]),
        .touch_way_i(nb_hit_way),
        .ages_o(nb_ages_next),
        .victim_o()
    );
    pycore_cache_lru #(.WAYS(WAYS)) u_lru_ins_v (
        .ages_i(ages_q[ins_set]),
        .touch_way_i('0),
        .ages_o(),
        .victim_o(ins_lru_victim)
    );
    pycore_cache_lru #(.WAYS(WAYS)) u_lru_ins_t (
        .ages_i(ages_q[ins_set]),
        .touch_way_i(ins_way),
        .ages_o(ins_ages_next),
        .victim_o()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign rq_room = (rq_cnt_r < (RQ_W+1)'(RQ_DEPTH));
    // The oldest slot has its line (or its fault) and can install now.
    assign ins_ready = NB && (ms_done_r != '0) &&
                       (ms_fault_q[ins_slot] || !ins_dirty_victim || !wbb_v_r) &&
                       (ms_pf_q[ins_slot] || rq_room);
    assign leg_hit_ok = comb_hit &&
                        !(ZERO_LINE_BYPASS && c_we && c_line && (c_wline == '0)) &&
                        !(c_we && WRITE_INV_NO_ALLOC) && !(c_we && READ_ONLY) &&
                        (hit_cycles_eff <= 1);
    assign leg_take = cache_en_i && (state_r == ST_IDLE) && !inv_all_i && !flush_all_i &&
                      !pmiss_r && c_req && !(PIPE && pipe_i && !lp_v_r) && (pq_cnt_r == '0) &&
                      (!nb_busy || leg_hit_ok);
    assign lp_cap   = NB && cache_en_i && (state_r == ST_IDLE) && !inv_all_i && !flush_all_i &&
                      req_i && !lp_v_r && !leg_take;
    // An ordinary hit and an install both touch the set's ages; the hit wins.
    assign ins_now  = ins_ready && !leg_take;
    // A waiting ordinary request blocks new non-blocking reads, so the port
    // drains and the ordinary miss path gets the down port.
    assign nb_gnt_o = NB && cache_en_i && (state_r == ST_IDLE) && !inv_all_i && !flush_all_i &&
                      !c_req && !ins_ready &&
                      (nb_pf_i ? (nb_hit || nb_inflight || nb_wbconf ||
                                  (ms_cnt_r < (NS_W+1)'(NB_SLOTS)))
                               : (rq_room && (nb_hit || (!nb_inflight && !nb_wbconf &&
                                  (ms_cnt_r < (NS_W+1)'(NB_SLOTS))))));
    assign nb_take  = nb_req_i && nb_gnt_o;

    // Down request: the writeback buffer first, then the next unissued slot.
    always_comb begin
        nbd_req  = 1'b0;
        nbd_we   = 1'b0;
        nbd_addr = '0;
        if (NB && (dq_cnt_r < (DQ_W+1)'(DQ_DEPTH))) begin
            if (wbb_v_r && !wbb_iss_r) begin
                nbd_req  = 1'b1;
                nbd_we   = 1'b1;
                nbd_addr = wbb_addr_r;
            end else if (ms_iss_r < ms_cnt_r) begin
                nbd_req  = 1'b1;
                nbd_addr = ms_addr_q[iss_slot];
            end
        end
    end

    assign nb_ack_o   = NB && (rq_cnt_r != '0);
    assign nb_id_o    = rq_id_q[rq_head_r];
    assign nb_fault_o = nb_ack_o && rq_fault_q[rq_head_r];
    assign nb_line_o  = rq_line_q[rq_head_r];
    assign gnt_o      = pipe_ok;
    assign last_o     = cache_en_i ? last_r : 1'b1;

    // --- CPU-facing and down-facing mux (CACHE_EN=0 is combinational) -----
    assign ack_o   = cache_en_i ? ack_r   : down_ack_i;
    assign rdata_o = cache_en_i ? rdata_r : down_rdata_i;
    assign fault_o = cache_en_i ? fault_r : down_fault_i;
    assign rdata_line_o = cache_en_i ? rline_r : '0;

    // NB requests own the down port while the port is busy; the ordinary
    // miss path only runs when it is drained (down_req_r is then the only
    // source).
    assign down_req_o   = cache_en_i ? (down_req_r || nbd_req) : req_i;
    assign down_pipe_o  = cache_en_i && nbd_req;
    assign down_we_o    = cache_en_i ? (nbd_req ? nbd_we : down_we_r) : we_i;
    assign down_line_o  = cache_en_i ? (nbd_req || down_line_r) : line_i;
    assign down_wstrb_o = cache_en_i ? (nbd_req ? {DATA_WIDTH/8{1'b1}} : down_wstrb_r) : wstrb_i;
    assign down_addr_o  = cache_en_i ? (nbd_req ? nbd_addr : down_addr_r)
                                     : {addr_i[ADDR_WIDTH-1:WORD_SHIFT], {WORD_SHIFT{1'b0}}};
    assign down_wdata_o = cache_en_i
                        ? ((state_r == ST_WB_WAIT || state_r == ST_WB_ISSUE ||
                            state_r == ST_FLUSH_WB_WAIT || state_r == ST_FLUSH_WB_ISSUE)
                               ? line_word(wb_line_r, beat_r)
                               : cap_wdata_r)
                        : wdata_i;
    assign down_wline_o = cache_en_i
                        ? (nbd_req ? wbb_line_r
                           : (((state_r == ST_ZL_ISSUE) || (state_r == ST_ZL_WAIT))
                               ? cap_wline_r : wb_line_r))
                        : wline_i;

    assign hit_count_o       = hit_count_r;
    assign miss_count_o      = miss_count_r;
    assign writeback_count_o = writeback_count_r;
    assign region_hit_count_o  = region_hit_count_r;
    assign region_miss_count_o = region_miss_count_r;
    assign idle_o            = (state_r == ST_IDLE) && !nb_busy && !pmiss_r && !lp_v_r &&
                               (pq_cnt_r == '0);
    assign inv_busy_o        = (state_r == ST_INV);
    assign flush_busy_o      = (state_r == ST_FLUSH_SCAN) ||
                               (state_r == ST_FLUSH_WB_ISSUE) ||
                               (state_r == ST_FLUSH_WB_WAIT);
    assign inv_done_o        = inv_done_r;
    assign flush_done_o      = flush_done_r;

    // Flush/inv take priority over req in ST_IDLE, so a same-cycle request
    // is dropped (no ack). The handoff sequencer waits for idle_o before
    // pulsing flush/inv; this is the backstop if that gate ever slips.
    always_ff @(posedge clk_i) begin
        if (rst_n_i && cache_en_i && req_i &&
            (flush_all_i || inv_all_i || flush_busy_o || inv_busy_o))
            $error("%m: req_i while flush/inv (request would be dropped)");
    end

`ifndef SYNTHESIS
    initial begin
        if (NB && ((NB_SLOTS & (NB_SLOTS - 1)) != 0 || NB_SLOTS < 2))
            $fatal(1, "%m: NB_SLOTS must be a power of two, at least 2");
        if (PIPE && ((PQ_DEPTH & (PQ_DEPTH - 1)) != 0 || PQ_DEPTH < 2))
            $fatal(1, "%m: PQ_DEPTH must be a power of two, at least 2");
    end
    always_ff @(posedge clk_i) begin
        if (rst_n_i && NB && cache_en_i && (state_r != ST_IDLE) && nb_busy)
            $error("%m: miss path running while non-blocking fills are in flight");
        if (rst_n_i && PIPE && cache_en_i && req_i && pipe_i && !(we_i ? line_i : 1'b1))
            $error("%m: pipelined write must be a line write");
        if (rst_n_i && !PIPE && req_i && pipe_i)
            $error("%m: pipelined request to a cache without PIPE");
    end
`endif

    wire req_in_region = (REGION_LIMIT != 32'd0) &&
                         (c_addr >= ADDR_WIDTH'(REGION_BASE)) &&
                         (c_addr <  ADDR_WIDTH'(REGION_LIMIT));
    wire down_beat_last = DOWN_LINE ? down_last_i
                                    : (beat_r == BEAT_W'(BEATS - 1));
    wire [ADDR_WIDTH-1:0] down_fill_addr =
        line_align(cap_addr_r) + (DOWN_LINE ? '0
                                            : (ADDR_WIDTH'(beat_r) << WORD_SHIFT));
    wire [ADDR_WIDTH-1:0] down_wb_addr =
        wb_addr_r + (DOWN_LINE ? '0 : (ADDR_WIDTH'(beat_r) << WORD_SHIFT));


    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r     <= ST_IDLE;
            cap_we_r    <= 1'b0;
            cap_wstrb_r <= '0;
            cap_addr_r  <= '0;
            cap_wdata_r <= '0;
            cap_way_r   <= '0;
            cap_line_r  <= '0;
            cap_line_wr_r <= 1'b0;
            cap_wline_r <= '0;
            beat_r      <= '0;
            wb_addr_r   <= '0;
            wb_line_r   <= '0;
            hit_wait_r  <= 0;
            flush_set_r <= '0;
            flush_way_r <= '0;
            ack_r       <= 1'b0;
            fault_r     <= 1'b0;
            rdata_r     <= '0;
            rline_r     <= '0;
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
            lp_v_r      <= 1'b0;
            lp_we_r     <= 1'b0;
            lp_line_r   <= 1'b0;
            lp_wstrb_r  <= '0;
            lp_addr_r   <= '0;
            lp_wdata_r  <= '0;
            lp_wline_r  <= '0;
            pq_head_r   <= '0;
            pq_cnt_r    <= '0;
            pq_beat_r   <= '0;
            cyc_r       <= '0;
            pmiss_r     <= 1'b0;
            cap_pipe_r  <= 1'b0;
            last_r      <= 1'b1;
            for (int i = 0; i < PQ_DEPTH; i++) begin
                pq_rd_q[i]    <= 1'b0;
                pq_fault_q[i] <= 1'b0;
                pq_line_q[i]  <= '0;
                pq_at_q[i]    <= '0;
            end
            ms_head_r  <= '0;
            ms_cnt_r   <= '0;
            ms_iss_r   <= '0;
            ms_done_r  <= '0;
            ms_beat_r  <= '0;
            for (int i = 0; i < NB_SLOTS; i++) begin
                ms_addr_q[i]  <= '0;
                ms_id_q[i]    <= '0;
                ms_pf_q[i]    <= 1'b0;
                ms_fault_q[i] <= 1'b0;
                ms_line_q[i]  <= '0;
            end
            wbb_v_r    <= 1'b0;
            wbb_iss_r  <= 1'b0;
            wbb_addr_r <= '0;
            wbb_line_r <= '0;
            dq_head_r  <= '0;
            dq_cnt_r   <= '0;
            for (int i = 0; i < DQ_DEPTH; i++) dq_wr_q[i] <= 1'b0;
            rq_head_r  <= '0;
            rq_cnt_r   <= '0;
            for (int i = 0; i < RQ_DEPTH; i++) begin
                rq_id_q[i]    <= '0;
                rq_fault_q[i] <= 1'b0;
                rq_line_q[i]  <= '0;
            end
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
            // Pipelined-response queue push (one per cycle at most: a
            // pipelined hit is taken in ST_IDLE, every other push comes from
            // the miss path, which runs only outside it).
            logic              pq_push, pq_push_rd, pq_push_fault, pq_pop;
            logic [LINE_W-1:0] pq_push_line;
            logic [31:0]       pq_push_at;
            pq_push       = 1'b0;
            pq_push_rd    = 1'b0;
            pq_push_fault = 1'b0;
            pq_push_line  = '0;
            pq_push_at    = cyc_r;
            pq_pop        = 1'b0;

            ack_r        <= 1'b0;
            fault_r      <= 1'b0;
            down_req_r   <= 1'b0;
            inv_done_r   <= 1'b0;
            flush_done_r <= 1'b0;
            last_r       <= 1'b1;
            cyc_r        <= cyc_r + 32'd1;

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
                    end else if (pmiss_r) begin
                        // A pipelined miss waits for the responses ahead
                        // of it, then takes the miss path.
                        if (pq_cnt_r == '0)
                            state_r <= ST_PMISS;
                    end else if (pipe_take) begin
                        if (comb_hit) begin
                            hit_count_r     <= hit_count_r + 1'b1;
                            ages_q[req_set] <= lru_ages_next;
                            if (we_i) begin
                                data_q[req_set][comb_hit_way]  <= wline_i;
                                dirty_q[req_set][comb_hit_way] <= 1'b1;
                            end
                            pq_push      = 1'b1;
                            pq_push_rd   = !we_i;
                            pq_push_line = data_q[req_set][comb_hit_way];
                            pq_push_at   = cyc_r + 32'(hit_cycles_eff);
                        end else begin
                            miss_count_r  <= miss_count_r + 1'b1;
                            cap_we_r      <= we_i;
                            cap_wstrb_r   <= wstrb_i;
                            cap_addr_r    <= addr_i;
                            cap_wdata_r   <= wdata_i;
                            cap_line_wr_r <= we_i;
                            cap_wline_r   <= wline_i;
                            cap_pipe_r    <= 1'b1;
                            pmiss_r       <= 1'b1;
                        end
                    end else if (leg_take) begin
                        cap_we_r    <= c_we;
                        cap_wstrb_r <= c_wstrb;
                        cap_addr_r  <= c_addr;
                        cap_wdata_r <= c_wdata;
                        cap_line_wr_r <= c_we && c_line;
                        cap_wline_r <= c_wline;
                        if (ZERO_LINE_BYPASS && c_we && c_line && (c_wline == '0)) begin
                            // The target line is wholly overwritten. A hit is
                            // invalidated locally; L2 receives the zero line
                            // atomically and handles its own victim normally.
                            if (comb_hit) begin
                                valid_q[req_set][comb_hit_way] <= 1'b0;
                                dirty_q[req_set][comb_hit_way] <= 1'b0;
                                hit_count_r <= hit_count_r + 1'b1;
                            end else begin
                                miss_count_r <= miss_count_r + 1'b1;
                            end
                            state_r <= ST_ZL_ISSUE;
                        end else if (c_we && WRITE_INV_NO_ALLOC) begin
                            if (comb_hit) begin
                                valid_q[req_set][comb_hit_way] <= 1'b0;
                                dirty_q[req_set][comb_hit_way] <= 1'b0;
                            end
                            state_r <= ST_WT_ISSUE;
                        end else if (c_we && READ_ONLY) begin
                            ack_r   <= 1'b1;
                            fault_r <= 1'b1;
                            rdata_r <= '0;
                        end else if (comb_hit) begin
                            cap_way_r          <= comb_hit_way;
                            ages_q[req_set]    <= lru_ages_next;
                            hit_count_r        <= hit_count_r + 1'b1;
                            if (req_in_region)
                                region_hit_count_r <= region_hit_count_r + 1'b1;
                            if (c_we && c_line) begin
                                data_q[req_set][comb_hit_way] <= c_wline;
                                dirty_q[req_set][comb_hit_way] <= 1'b1;
                            end else if (c_we) begin
                                data_q[req_set][comb_hit_way] <=
                                    merge_word(data_q[req_set][comb_hit_way],
                                               req_word, c_wdata, c_wstrb);
                                dirty_q[req_set][comb_hit_way] <= 1'b1;
                            end
                            if (hit_cycles_eff <= 1) begin
                                ack_r   <= 1'b1;
                                rdata_r <= c_line
                                         ? line_word(c_wline, req_word)
                                         : line_word(data_q[req_set][comb_hit_way],
                                                     req_word);
                                rline_r <= c_line ? c_wline
                                         : data_q[req_set][comb_hit_way];
                            end else begin
                                hit_wait_r <= hit_cycles_eff - 1;
                                state_r    <= ST_HIT_WAIT;
                            end
                        end else begin
                            miss_count_r <= miss_count_r + 1'b1;
                            if (req_in_region)
                                region_miss_count_r <= region_miss_count_r + 1'b1;
                            cap_way_r    <= victim_way;
                            if (c_we && c_line &&
                                !(valid_q[req_set][victim_way] &&
                                  dirty_q[req_set][victim_way] &&
                                  WRITE_BACK)) begin
                                // Write-full-line / no-allocate: install without fill.
                                data_q[req_set][victim_way]  <= c_wline;
                                tag_q[req_set][victim_way]   <= req_tag;
                                valid_q[req_set][victim_way] <= 1'b1;
                                dirty_q[req_set][victim_way] <= 1'b1;
                                ages_q[req_set]              <= lru_ages_next;
                                ack_r   <= 1'b1;
                                rdata_r <= line_word(c_wline, req_word);
                                rline_r <= c_wline;
                            end else if (c_we && !WRITE_BACK) begin
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
                    rline_r <= data_q[cap_set][cap_way_r];
                    state_r <= ST_IDLE;
                end
                ST_FAULT: begin
                    if (cap_pipe_r) begin
                        pq_push       = 1'b1;
                        pq_push_fault = 1'b1;
                        cap_pipe_r    <= 1'b0;
                        pmiss_r       <= 1'b0;
                    end else begin
                        ack_r   <= 1'b1;
                        fault_r <= 1'b1;
                        rdata_r <= '0;
                    end
                    state_r <= ST_IDLE;
                end
                // Pipelined miss, queue drained: pick the victim in cap_set
                // and continue on the ordinary miss path.
                ST_PMISS: begin
                    logic [WAY_W-1:0] v;
                    v = cap_have_free ? cap_free_way : lru_victim;
                    cap_way_r <= v;
                    if (valid_q[cap_set][v] && dirty_q[cap_set][v] && WRITE_BACK) begin
                        wb_addr_r <= make_addr(tag_q[cap_set][v], cap_set);
                        wb_line_r <= data_q[cap_set][v];
                        beat_r    <= '0;
                        state_r   <= ST_WB_ISSUE;
                    end else if (cap_line_wr_r) begin
                        state_r   <= ST_PINST;
                    end else begin
                        beat_r     <= '0;
                        cap_line_r <= '0;
                        state_r    <= ST_FILL_ISSUE;
                    end
                end
                ST_PINST: begin
                    data_q[cap_set][cap_way_r]  <= cap_wline_r;
                    tag_q[cap_set][cap_way_r]   <= cap_tag;
                    valid_q[cap_set][cap_way_r] <= 1'b1;
                    dirty_q[cap_set][cap_way_r] <= 1'b1;
                    ages_q[cap_set]             <= lru_ages_next;
                    pq_push    = 1'b1;
                    cap_pipe_r <= 1'b0;
                    pmiss_r    <= 1'b0;
                    state_r    <= ST_IDLE;
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
                            if (cap_line_wr_r) begin
                                data_q[cap_set][cap_way_r]  <= cap_wline_r;
                                tag_q[cap_set][cap_way_r]   <= cap_tag;
                                valid_q[cap_set][cap_way_r] <= 1'b1;
                                dirty_q[cap_set][cap_way_r] <= 1'b1;
                                ages_q[cap_set]             <= lru_ages_next;
                                if (cap_pipe_r) begin
                                    pq_push    = 1'b1;
                                    cap_pipe_r <= 1'b0;
                                    pmiss_r    <= 1'b0;
                                end else begin
                                    ack_r   <= 1'b1;
                                    rdata_r <= line_word(cap_wline_r, cap_word);
                                    rline_r <= cap_wline_r;
                                end
                                state_r <= ST_IDLE;
                            end else begin
                                beat_r     <= '0;
                                cap_line_r <= '0;
                                state_r    <= ST_FILL_ISSUE;
                            end
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
                                if (cap_pipe_r) begin
                                    pq_push      = 1'b1;
                                    pq_push_rd   = 1'b1;
                                    pq_push_line = installed;
                                    cap_pipe_r   <= 1'b0;
                                    pmiss_r      <= 1'b0;
                                end else begin
                                    ack_r   <= 1'b1;
                                    rdata_r <= line_word(installed, cap_word);
                                    rline_r <= installed;
                                end
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
                ST_ZL_ISSUE: begin
                    down_req_r   <= 1'b1;
                    down_we_r    <= 1'b1;
                    down_line_r  <= 1'b1;
                    down_wstrb_r <= {DATA_WIDTH/8{1'b1}};
                    down_addr_r  <= line_align(cap_addr_r);
                    state_r      <= ST_ZL_WAIT;
                end
                ST_ZL_WAIT: begin
                    if (down_ack_i) begin
                        if (down_fault_i)
                            state_r <= ST_FAULT;
                        else begin
                            ack_r   <= 1'b1;
                            rdata_r <= '0;
                            rline_r <= '0;
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
                    // Deliberate area/timing trade for a research core:
                    // clear every valid/dirty flop in one cycle (L2: 256
                    // sets × 8 ways = 2048). Do not turn this into a
                    // multi-cycle walk without re-checking the handoff
                    // sequencer's inv_done pulse.
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

            // ---- Pipelined responses, oldest first ----------------------
            if (PIPE && cache_en_i && (pq_cnt_r != '0) && (cyc_r >= pq_at_q[pq_head_r])) begin
                ack_r   <= 1'b1;
                fault_r <= pq_fault_q[pq_head_r];
                if (pq_rd_q[pq_head_r] && !pq_fault_q[pq_head_r]) begin
                    rdata_r <= line_word(pq_line_q[pq_head_r], pq_beat_r);
                    rline_r <= pq_line_q[pq_head_r];
                    last_r  <= (pq_beat_r == BEAT_W'(BEATS - 1));
                    if (pq_beat_r == BEAT_W'(BEATS - 1)) begin
                        pq_pop    = 1'b1;
                        pq_beat_r <= '0;
                    end else begin
                        pq_beat_r <= pq_beat_r + BEAT_W'(1);
                    end
                end else begin
                    rdata_r <= '0;
                    pq_pop  = 1'b1;
                end
            end
            if (PIPE && pq_push) begin
                logic [PQ_W-1:0] t;
                t = PQ_W'(pq_head_r + PQ_W'(pq_cnt_r));
                pq_rd_q[t]    <= pq_push_rd;
                pq_fault_q[t] <= pq_push_fault;
                pq_line_q[t]  <= pq_push_line;
                pq_at_q[t]    <= pq_push_at;
            end
            if (pq_pop) pq_head_r <= pq_head_r + PQ_W'(1);
            pq_cnt_r <= pq_cnt_r + (PQ_W+1)'(pq_push) - (PQ_W+1)'(pq_pop);

            // ---- Held ordinary request (NB) --------------------------------
            if (lp_cap) begin
                lp_v_r     <= 1'b1;
                lp_we_r    <= we_i;
                lp_line_r  <= line_i;
                lp_wstrb_r <= wstrb_i;
                lp_addr_r  <= addr_i;
                lp_wdata_r <= wdata_i;
                lp_wline_r <= wline_i;
            end else if (lp_v_r && leg_take) begin
                lp_v_r <= 1'b0;
            end

            // ---- Non-blocking port ----------------------------------------
            if (NB && cache_en_i) begin
                logic              rq_push, rq_push_fault;
                logic [3:0]        rq_push_id;
                logic [LINE_W-1:0] rq_push_line;
                logic              ms_add, ms_issued, ms_filled, dq_push, dq_pop;
                rq_push       = 1'b0;
                rq_push_fault = 1'b0;
                rq_push_id    = '0;
                rq_push_line  = '0;
                ms_add        = 1'b0;
                ms_issued     = 1'b0;
                ms_filled     = 1'b0;
                dq_push       = 1'b0;
                dq_pop        = 1'b0;

                // Accept (never in the same cycle as an install).
                if (nb_take) begin
                    if (nb_hit) begin
                        hit_count_r    <= hit_count_r + 1'b1;
                        ages_q[nb_set] <= nb_ages_next;
                        if (!nb_pf_i) begin
                            rq_push      = 1'b1;
                            rq_push_id   = nb_id_i;
                            rq_push_line = data_q[nb_set][nb_hit_way];
                        end
                    end else if (!(nb_inflight || nb_wbconf)) begin
                        logic [NS_W-1:0] t;
                        t = NS_W'(ms_head_r + NS_W'(ms_cnt_r));
                        miss_count_r  <= miss_count_r + 1'b1;
                        ms_addr_q[t]  <= nb_laddr;
                        ms_id_q[t]    <= nb_id_i;
                        ms_pf_q[t]    <= nb_pf_i;
                        ms_fault_q[t] <= 1'b0;
                        ms_add = 1'b1;
                    end
                    // else: a prefetch of a line already on its way; dropped.
                end

                // Issue down.
                if (nbd_req && down_gnt_i) begin
                    dq_push = 1'b1;
                    dq_wr_q[DQ_W'(dq_head_r + DQ_W'(dq_cnt_r))] <= nbd_we;
                    if (nbd_we) begin
                        wbb_iss_r         <= 1'b1;
                        writeback_count_r <= writeback_count_r + 1'b1;
                    end else begin
                        ms_issued = 1'b1;
                    end
                end

                // Down responses, in issue order.
                if (down_ack_i && (dq_cnt_r != '0)) begin
                    if (dq_wr_q[dq_head_r]) begin
                        dq_pop = 1'b1;
                        wbb_v_r   <= 1'b0;
                        wbb_iss_r <= 1'b0;
                    end else begin
                        logic [NS_W-1:0] f;
                        f = NS_W'(ms_head_r + NS_W'(ms_done_r));
                        if (down_fault_i) begin
                            ms_fault_q[f] <= 1'b1;
                            ms_beat_r <= '0;
                            ms_filled = 1'b1;
                            dq_pop    = 1'b1;
                        end else begin
                            ms_line_q[f][ms_beat_r*DATA_WIDTH +: DATA_WIDTH] <= down_rdata_i;
                            if (down_last_i) begin
                                ms_beat_r <= '0;
                                ms_filled = 1'b1;
                                dq_pop    = 1'b1;
                            end else begin
                                ms_beat_r <= ms_beat_r + BEAT_W'(1);
                            end
                        end
                    end
                end

                // Install the oldest filled slot.
                if (ins_now) begin
                    if (!ms_fault_q[ins_slot]) begin
                        if (ins_dirty_victim) begin
                            wbb_v_r    <= 1'b1;
                            wbb_iss_r  <= 1'b0;
                            wbb_addr_r <= make_addr(tag_q[ins_set][ins_way], ins_set);
                            wbb_line_r <= data_q[ins_set][ins_way];
                        end
                        data_q[ins_set][ins_way]  <= ms_line_q[ins_slot];
                        tag_q[ins_set][ins_way]   <= ins_tag;
                        valid_q[ins_set][ins_way] <= 1'b1;
                        dirty_q[ins_set][ins_way] <= 1'b0;
                        ages_q[ins_set]           <= ins_ages_next;
                    end
                    if (!ms_pf_q[ins_slot]) begin
                        rq_push       = 1'b1;
                        rq_push_id    = ms_id_q[ins_slot];
                        rq_push_fault = ms_fault_q[ins_slot];
                        rq_push_line  = ms_line_q[ins_slot];
                    end
                    ms_head_r <= ms_head_r + NS_W'(1);
                end
                ms_cnt_r  <= ms_cnt_r  + (NS_W+1)'(ms_add)    - (NS_W+1)'(ins_now);
                ms_iss_r  <= ms_iss_r  + (NS_W+1)'(ms_issued) - (NS_W+1)'(ins_now);
                ms_done_r <= ms_done_r + (NS_W+1)'(ms_filled) - (NS_W+1)'(ins_now);
                if (dq_pop) dq_head_r <= dq_head_r + DQ_W'(1);
                dq_cnt_r <= dq_cnt_r + (DQ_W+1)'(dq_push) - (DQ_W+1)'(dq_pop);

                // Responses: the head leaves every cycle.
                if (rq_push) begin
                    logic [RQ_W-1:0] t;
                    t = RQ_W'(rq_head_r + RQ_W'(rq_cnt_r));
                    rq_id_q[t]    <= rq_push_id;
                    rq_fault_q[t] <= rq_push_fault;
                    rq_line_q[t]  <= rq_push_line;
                end
                if (rq_cnt_r != '0) rq_head_r <= rq_head_r + RQ_W'(1);
                rq_cnt_r <= rq_cnt_r + (RQ_W+1)'(rq_push) - (RQ_W+1)'(rq_cnt_r != '0);
            end
        end
    end
endmodule
