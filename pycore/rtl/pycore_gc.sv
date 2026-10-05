`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Entries and memory words are wider than any one consumer reads.
/* verilator lint_off UNUSEDSIGNAL */
// pycore_gc: precise, stop-the-world, non-moving mark-and-sweep engine
// (planning/gc_plan.md §4, pycore/docs/gc.md).
//
// A core-side dmem master, muxed into the core's port beside STRACC. The core
// starts it at an instruction boundary, streams the register and RF roots
// through root_valid/root_entry, and waits for done.
//
// Structure (Phase R decisions, gc.md §"Prior art"):
//   cleanup - drops idle compiler-arena references named by image metadata.
//   tracer  - walks memory: the memory-resident roots (boot record, native
//             table, StopIteration sidecar, RF spill, exception stack,
//             frames) and the slots of every popped object. It emits child
//             handles, and RAW extents for headerless buffers, into a queue.
//   marker  - owns the mark bitmap and the mark stack. For each queued item
//             it tests the first granule, sets every granule of the extent
//             (extent marking), and pushes pushable kinds. It also runs the
//             sweep, which clears the bitmap as it scans (Bacon).
//   queue   - 4 entries between producers (root stream, tracer) and marker.
//   port    - one outstanding request; the marker wins ties.
//
// Bitmap: BM_WORDS (heap limit / 2 KB) x 128-bit on-chip words; bit g <=> granule g = addr >> 4.
// Mark stack: MSTACK_ONCHIP-entry ring; the oldest SPILL_BATCH entries spill
// to PYCORE_GC_MARK_STACK when it is full and refill when it is empty.
// Wide ranges: one pop scans at most SCAN_CHUNK slots of a tuple, list
// buffer, set table, or dict order buffer / table. The rest of the range is
// pushed first as a continuation entry (K_TUPLE for 32 B slots, K_DICTT for
// 64 B dict slots), so a wide container holds at most SCAN_CHUNK + 1 entries.
// Stack full: a child that does not fit is left unmarked and the range being
// scanned (t_re_r) is written once to the rescan list at PYCORE_GC_RESCAN.
// When the stack drains, recorded ranges are pushed back and scanned again;
// marked children are skipped, so each rescan makes progress. The collection
// is abandoned (overflow_r) only when the rescan list itself is full.
// Free runs: the first 1024 listed runs stay on-chip (G13 P4); overflow
// headers { FREE_MAGIC, size, next, base } live in PYCORE_GC_RUN_TABLE
// after that window; once the table is full they go in place, in the run's
// first granule. Leftover headers may still sit in-place (base=0).
module pycore_gc #(
    parameter int MSTACK_ONCHIP = 256,
    parameter int SPILL_BATCH   = 32,
    parameter logic [31:0] STACK_ENTRIES = PYCORE_GC_MARK_STACK_ENTRIES,
    parameter logic [31:0] RESCAN_ENTRIES = PYCORE_GC_RESCAN_ENTRIES,
    parameter logic [31:0] SCAN_CHUNK = PYCORE_GC_SCAN_CHUNK
) (
    input  logic         clk_i,
    input  logic         rst_n_i,
    input  logic         start_i,
    output logic         busy_o,
    output logic         done_o,
    // Configuration, sampled at start.
    input  logic [31:0]  dyn_base_i,
    input  logic [31:0]  heap_limit_i,
    input  logic [31:0]  spill_sp_i,
    input  logic [31:0]  exc_sp_i,
    input  logic [31:0]  frame_depth_i,
    input  logic         stash_en_i,
    input  logic         poison_en_i,
    // Poison may use 64 B full-line writes (CACHE_EN=1 only: with the cache
    // off the hierarchy carries 16 B words). Simulation speed only.
    input  logic         line_wr_ok_i,
    // [zero_base_i, heap_limit_i) has never been written; poison stops there
    // so memory the allocator hands out without zeroing stays zero.
    input  logic [31:0]  zero_base_i,
    // Current allocation run kept across a collection that has no
    // allocation to satisfy: [keep_lo_i, keep_hi_i) holds no object and is
    // never written. The sweep treats it as allocated (so no listed run
    // overlaps it) but counts it as free. keep_hi_i <= keep_lo_i: none.
    input  logic [31:0]  keep_lo_i,
    input  logic [31:0]  keep_hi_i,
    // Next-fit position: run_rover_o counts listed on-chip runs whose base
    // is below rover_addr_i (0: none, plain first-fit).
    input  logic [31:0]  rover_addr_i,
    // Idle compiler cleanup: skip the slot loop when nothing outside the
    // collector has written _PYC_G["_busy"] since the last completed loop
    // (the core watches clean_busy_addr_o). Premarks still apply.
    input  logic         clean_skip_i,
    // Trace PYCORE_GC_EXTRA_ROOTS (a type dict has been handed to the program;
    // until then every type dict still holds only its static contents).
    input  logic         extra_roots_i,
    output logic [31:0]  clean_busy_addr_o,
    output logic         clean_done_o,
    input  logic [31:0]  stack_limit_i,
    input  logic [7:0]   onchip_limit_i,
    // Rescan-list entries (0: RESCAN_ENTRIES); tests shrink it to reach the
    // abort path.
    input  logic [31:0]  rescan_limit_i,
    input  logic [7:0]   mutant_i,
    // Register / RF root stream.
    input  logic         root_valid_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] root_entry_i,
    input  logic         roots_done_i,
    output logic         root_ready_o,
    // dmem master.
    output logic         req_o,
    output logic         we_o,
    output logic         line_o,
    output logic [31:0]  addr_o,
    output logic [127:0] wdata_o,
    output logic [15:0]  wstrb_o,
    input  logic         ack_i,
    input  logic [127:0] rdata_i,
    input  logic [PYCORE_LINE_BYTES*8-1:0] rline_i,
    input  logic         fault_i,
    input  logic         cache_en_i,
    // Results (valid from done until the next start).
    output logic [31:0]  live_bytes_o,
    output logic [31:0]  free_bytes_o,
    output logic [31:0]  largest_base_o,
    output logic [31:0]  largest_size_o,
    output logic [31:0]  run_head_o,
    output logic [31:0]  runs_o,
    // On-chip run list (G13 P4): the first RUN_ONCHIP listed runs stay in
    // registers so sweep does not pay a cold miss per header. Overflow
    // continues in the sequential table. The allocator peeks by index;
    // dumps serialize the on-chip words at PYCORE_GC_RUN_TABLE.
    output logic [31:0]  run_onchip_n_o,
    // On-chip runs that lie below rover_addr_i: the allocator starts its
    // next search there (next-fit across collections).
    output logic [31:0]  run_rover_o,
    output logic [31:0]  run_overflow_head_o,
    input  logic [9:0]   run_peek_idx_i,
    output logic [31:0]  run_peek_base_o,
    output logic [31:0]  run_peek_size_o,
    output logic         stack_overflow_o,
    output logic         fault_o,
    output logic [31:0]  bad_kind_o,
    output logic [31:0]  reserved_tag_o,
    output logic [31:0]  wild_ptr_o,
    // Performance counters (per collection).
    output logic [31:0]  mark_cyc_o,
    output logic [31:0]  sweep_cyc_o,
    output logic [31:0]  port_busy_mark_o,
    output logic [31:0]  mark_xacts_o,
    output logic [31:0]  spill_xacts_o,
    output logic [31:0]  stack_hw_o,
    output logic [31:0]  stash_cyc_o,
    output logic [31:0]  objects_o,
    output logic [31:0]  roots_o,
    output logic [31:0]  rescans_o,         // ranges written to the rescan list
    // One past the highest heap byte the sweep wrote (headers, poison).
    output logic [31:0]  dirty_hi_o,
    // Debug: one pulse per free run emitted by the sweep (shadow checker).
    output logic         free_range_valid_o,
    output logic [31:0]  free_range_base_o,
    output logic [31:0]  free_range_len_o
);
    localparam int BM_WORDS   = PYCORE_GC_BITMAP_WORDS;
    localparam int BM_AW      = $clog2(BM_WORDS);
    localparam int OC_AW      = $clog2(MSTACK_ONCHIP);
    localparam int RUN_ONCHIP = 1024;

    // ---------------------------------------------------------------------
    // Phases
    // ---------------------------------------------------------------------
    typedef enum logic [3:0] {
        P_IDLE, P_CLEAR, P_CLEANUP, P_PRELOAD, P_ROOTS_REG, P_ROOTS_MEM,
        P_MARK, P_SWEEP, P_FINISH
    } phase_e;
    phase_e phase_r;

    // Mark-stack entry kinds.
    localparam logic [2:0] K_TUPLE = 3'd0;
    localparam logic [2:0] K_CODE  = 3'd1;
    localparam logic [2:0] K_LIST  = 3'd2;
    localparam logic [2:0] K_DICT  = 3'd3;
    localparam logic [2:0] K_SET   = 3'd4;
    localparam logic [2:0] K_OBJ   = 3'd5;
    localparam logic [2:0] K_STR   = 3'd6;
    localparam logic [2:0] K_DICTT = 3'd7;   // continuation: dict table slots

    // Latched configuration.
    logic [31:0] dyn_base_r, heap_limit_r, spill_sp_r, exc_sp_r, frame_depth_r;
    logic [31:0] keep_lo_r, keep_hi_r, keep_w_r, rover_addr_r;
    logic        extra_roots_r;
    logic        stash_en_r, poison_en_r;
    logic [31:0] stack_limit_r, rescan_limit_r;
    logic [8:0]  onchip_limit_r;
    logic [7:0]  mut_r;
    logic        bitmap_clean_r;

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function automatic logic is_ptr_tag(input logic [3:0] t);
        is_ptr_tag = (t == PY_TAG_ITER) || (t == PY_TAG_TUPLE) ||
                     (t == PY_TAG_LONG_STR) || (t == PY_TAG_MUT_COLLEC) ||
                     (t == PY_TAG_OBJECT) || (t == PY_TAG_RANGE) ||
                     (t == PY_TAG_CODE_OBJECT);
    endfunction

    function automatic logic is_reserved_tag(input logic [3:0] t);
        is_reserved_tag = (t == PY_TAG_BYTES) || (t == PY_TAG_FROZENSET);
    endfunction

    function automatic logic [31:0] pad16(input logic [31:0] n);
        pad16 = (n + 32'd15) & ~32'd15;
    endfunction

    // Slots of a range the current pop scans.
    function automatic logic [31:0] chunk(input logic [31:0] n);
        chunk = (n > SCAN_CHUNK) ? SCAN_CHUNK : n;
    endfunction

    // OBJECT extent by ob_kind; 0 = unknown kind.
    function automatic logic [31:0] obj_extent(input logic [31:0] kind);
        unique case (kind)
            PY_OBK_INSTANCE:     obj_extent = PYCORE_OBJ_INSTANCE_BYTES;
            PY_OBK_TYPE:         obj_extent = PYCORE_OBJ_TYPE_BYTES;
            PY_OBK_BOUND_METHOD: obj_extent = PYCORE_OBJ_BOUND_METHOD_BYTES;
            PY_OBK_BUILTIN:      obj_extent = PYCORE_OBJ_BUILTIN_BYTES;
            PY_OBK_BYTEARRAY:    obj_extent = PYCORE_OBJ_BYTEARRAY_BYTES;
            PY_OBK_EXCEPTION:    obj_extent = PYCORE_OBJ_EXCEPTION_BYTES;
            PY_OBK_CELL:         obj_extent = PYCORE_OBJ_CELL_BYTES;
            PY_OBK_FUNCTION:     obj_extent = PYCORE_OBJ_FUNCTION_BYTES;
            default:             obj_extent = 32'd0;
        endcase
    endfunction

    // ---------------------------------------------------------------------
    // Port arbiter: one outstanding request, marker wins ties.
    // ---------------------------------------------------------------------
    logic         out_r, out_owner_r;   // owner: 1 = marker
    logic         t_want_r, t_line_r;
    logic [31:0]  t_addr_r;
    logic         m_want_r, m_we_r, m_line_r;
    logic [31:0]  m_addr_r;
    logic [127:0] m_wdata_r;
    logic         grant_m, grant_t, t_ack, m_ack;
    assign grant_m = !out_r && m_want_r;
    assign grant_t = !out_r && !m_want_r && t_want_r;
    assign req_o   = grant_m || grant_t;
    assign we_o    = grant_m ? m_we_r : 1'b0;
    assign line_o  = (grant_t && t_line_r) || (grant_m && m_line_r);
    assign addr_o  = grant_m ? m_addr_r : t_addr_r;
    assign wdata_o = m_wdata_r;
    assign wstrb_o = 16'hFFFF;
    assign t_ack   = ack_i && out_r && !out_owner_r;
    assign m_ack   = ack_i && out_r && out_owner_r;

    // ---------------------------------------------------------------------
    // Queue: {stash, raw, tag, value}. raw: value = {len[63:0], addr[63:0]}.
    // ---------------------------------------------------------------------
    localparam int QW = 2 + 4 + 128;
    logic [QW-1:0] q_mem [0:3];
    logic [1:0]    q_rd_r, q_wr_r;
    logic [2:0]    q_cnt_r;
    logic          q_push, q_pop;
    logic [QW-1:0] q_din;
    logic [QW-1:0] q_dout;
    assign q_dout = q_mem[q_rd_r];

    // Tracer pending buffer (drained into the queue).
    logic [QW-1:0] tp_mem [0:2];
    logic [1:0]    tp_cnt_r;

    // Root stream acceptance.
    assign root_ready_o = (phase_r == P_ROOTS_REG) && (q_cnt_r < 3'd4);
    logic root_take;
    assign root_take = root_valid_i && root_ready_o;

    // ---------------------------------------------------------------------
    // Bitmap
    // ---------------------------------------------------------------------
    logic [127:0] bm_q [0:BM_WORDS-1];
    // On-chip copy of the static prune map (G13 P6b). The map is constant
    // for an image; the first PRELOAD fills it from PYCORE_GC_STATIC_MAP and
    // later ones copy one word per cycle instead of a dmem read per word.
    // Static images above SHADOW_WORDS*2 KB read the remainder from dmem.
    localparam int SHADOW_WORDS = 256;
    logic [127:0] shadow_q [0:SHADOW_WORDS-1];
    logic         shadow_ok_r;

    // ---------------------------------------------------------------------
    // Mark stack
    // ---------------------------------------------------------------------
    logic [66:0]  ring [0:MSTACK_ONCHIP-1];   // {kind[2:0], size[31:0], addr[31:0]}
    logic [OC_AW-1:0] bot_r;
    logic [OC_AW:0]   cnt_r;
    logic [31:0]  mem_cnt_r;
    logic [31:0]  stack_total, stack_hw_r;
    assign stack_total = {{(31-OC_AW){1'b0}}, cnt_r} + mem_cnt_r;
    // Full: the ring is full and so is the memory part (a push would fail).
    // Room: no item in flight (queue 4, pending 3, marker 1) can fail.
    logic         stk_full, stk_room8;
    assign stk_full  = (cnt_r >= (OC_AW+1)'(onchip_limit_r)) && (mem_cnt_r >= stack_limit_r);
    assign stk_room8 = (stack_total + 32'd8 <= 32'(onchip_limit_r) + stack_limit_r);
    // Rescan list (memory, LIFO). m_have_ent_r: an entry has been popped, so
    // every later overflowing child belongs to the tracer's range t_re_r.
    // m_resc_done_r: that range is already recorded.
    logic [31:0]  resc_cnt_r, rescans_r;
    logic         m_have_ent_r, m_resc_done_r;

    // Tracer <-> marker pop handshake.
    logic         pop_req;      // tracer in T_POP
    logic         pop_give_r;   // one-cycle: entry valid
    logic [66:0]  pop_ent_r;
    logic         mark_done_r;

    // ---------------------------------------------------------------------
    // Results / counters
    // ---------------------------------------------------------------------
    logic [31:0] free_bytes_r, largest_base_r, largest_size_r, run_head_r, runs_r;
    logic        overflow_r, fault_r;
    logic [31:0] bad_kind_r, reserved_r, wild_r;
    logic [31:0] mark_cyc_r, sweep_cyc_r, busy_mark_r, mark_xacts_r, spill_xacts_r;
    logic [31:0] stash_cyc_r, objects_r, roots_r, stash_cnt_r;
    logic        done_r;

    assign busy_o           = (phase_r != P_IDLE);
    assign done_o           = done_r;
    assign free_bytes_o     = free_bytes_r;
    assign live_bytes_o     = (heap_limit_r - dyn_base_r) - free_bytes_r;
    assign largest_base_o   = largest_base_r;
    assign largest_size_o   = largest_size_r;
    assign run_head_o       = run_head_r;
    assign runs_o           = runs_r;
    assign stack_overflow_o = overflow_r;
    assign fault_o          = fault_r;
    assign bad_kind_o       = bad_kind_r;
    assign reserved_tag_o   = reserved_r;
    assign wild_ptr_o       = wild_r;
    assign mark_cyc_o       = mark_cyc_r;
    assign sweep_cyc_o      = sweep_cyc_r;
    assign port_busy_mark_o = busy_mark_r;
    assign mark_xacts_o     = mark_xacts_r;
    assign spill_xacts_o    = spill_xacts_r;
    assign stack_hw_o       = stack_hw_r;
    assign stash_cyc_o      = stash_cyc_r;
    assign objects_o        = objects_r;
    assign roots_o          = roots_r;
    assign rescans_o        = rescans_r;

    // =====================================================================
    // Tracer
    // =====================================================================
    typedef enum logic [4:0] {
        T_IDLE, T_MEMROOT, T_SCAN, T_TAG_W, T_VAL_W, T_VTAG_W, T_VVAL_W,
        T_POP, T_HDR_W, T_HDR2_W, T_HDR3_W, T_BA_BUF_W, T_BA_CAP_W,
        T_VAL_ISSUE, T_VVAL_ISSUE, T_LINE_W, T_HDR_LINE_W, T_DONE
    } tstate_e;
    tstate_e t_st_r;

    // Scan descriptor.
    typedef enum logic [2:0] { SM_PLAIN, SM_DICTT, SM_EXC, SM_FRAME } smode_e;
    smode_e      t_mode_r;
    logic [31:0] t_ptr_r, t_left_r;
    logic [3:0]  t_tag_r;          // tag of the element being fetched
    // Continuation scan (dict table after the order buffer).
    logic        t_cont_r;
    logic [31:0] t_cont_ptr_r, t_cont_left_r;
    logic [3:0]  t_range_r;        // memory-root range index
    logic [66:0] t_ent_r;          // popped entry
    logic [66:0] t_re_r;           // range to record if a child overflows
    logic [31:0] t_a_r, t_b_r;     // header fields latched across reads

    wire [2:0]  t_kind  = t_ent_r[66:64];
    wire [31:0] t_eaddr = t_ent_r[31:0];

    function automatic logic [QW-1:0] qhandle(input logic [3:0] tag, input logic [127:0] v);
        qhandle = {1'b0, 1'b0, tag, v};
    endfunction
    function automatic logic [QW-1:0] qraw(input logic [31:0] a, input logic [31:0] len);
        qraw = {1'b0, 1'b1, 4'd0, 32'd0, len, 32'd0, a};
    endfunction
    // Continuation: push {k, n, a} unmarked (raw item with tag 1).
    function automatic logic [QW-1:0] qcont(input logic [2:0] k, input logic [31:0] n,
                                            input logic [31:0] a);
        qcont = {1'b0, 1'b1, 4'd1, 61'd0, k, n, a};
    endfunction

    // Drain one pending item per cycle into the queue when there is room and
    // the root stream is not using the queue input.
    logic tp_drain;
    assign tp_drain = (tp_cnt_r != 2'd0) && !root_take &&
                      ((q_cnt_r < 3'd4) || q_pop);

    // =====================================================================
    // Marker
    // =====================================================================
    typedef enum logic [5:0] {
        M_IDLE, M_CLEAR,
        M_CLEAN_HDR, M_CLEAN_HDR_W, M_CLEAN_BUSY_W, M_CLEAN_ADDR_W,
        M_CLEAN_VAL_W, M_CLEAN_TAG_W,
        M_PRE, M_PRE_W, M_STASH_V, M_STASH_VW, M_STASH_T, M_STASH_TW, M_DEC,
        M_TEST, M_SET, M_PUSH, M_SPILL, M_SPILL_W, M_REFILL, M_REFILL_W,
        M_RESC_WR, M_RESC_WR_W, M_RESC_RD, M_RESC_RD_W,
        M_SW_KEEP, M_SW_PRE, M_SW_SCAN, M_SW_LAST, M_SW_WR, M_SW_WR_W, M_FIN, M_FIN_W,
        M_DONE
    } mstate_e;
    mstate_e m_st_r;

    logic [QW-1:0] m_ent_r;
    logic [31:0]   m_g_r, m_g_end_r;    // granule cursor / last granule
    logic          m_push_r;            // push after marking
    logic [66:0]   m_pent_r;            // entry to push
    logic [31:0]   m_clr_r;             // clear / pre-sweep word index
    logic [5:0]    m_batch_r;
    // Image-provided compiler scratch cleanup descriptor.  When _PYC_G is
    // idle, clear its reference-valued arena slots before tracing so prior
    // compile() calls cannot retain their transient AST/emitter graphs.
    logic [31:0]   m_clean_count_r, m_clean_idx_r;
    logic [127:0]  m_clean_word_r;
    logic [31:0]   m_clean_addr_r, m_clean_pyc_g_r, m_clean_builtins_r;
    logic          m_clean_idle_r;
    logic [31:0]   clean_busy_addr_r;
    logic          clean_done_r;
    assign clean_busy_addr_o = clean_busy_addr_r;
    assign clean_done_o      = clean_done_r;

    // Decode of the latched queue entry (combinational).
    logic [3:0]   d_tag;
    logic [127:0] d_val;
    logic         d_raw;
    logic         d_cont;    // continuation entry {kind, size, addr} = d_val[66:0]
    logic [1:0]   d_act;     // 0 none, 1 raw set, 2 test+set (leaf), 3 test+set+push
    logic [31:0]  d_addr, d_len;
    logic [2:0]   d_kind;
    logic [31:0]  d_size;
    logic         d_wild, d_reserved, d_badkind;
    always_comb begin
        logic [3:0]  mk;
        logic [3:0]  ik;
        logic [31:0] ia;
        d_tag = m_ent_r[131:128];
        d_val = m_ent_r[127:0];
        d_raw = m_ent_r[132];
        d_cont = d_raw && (d_tag == 4'd1);
        d_act = 2'd0;
        d_addr = 32'd0;
        d_len = 32'd0;
        d_kind = K_TUPLE;
        d_size = 32'd0;
        d_wild = 1'b0;
        d_reserved = 1'b0;
        d_badkind = 1'b0;
        mk = d_val[127:124];
        ik = d_val[119:116];
        ia = d_val[31:0];
        if (d_cont) begin
            // Handled in M_DEC: no decode, no mark.
        end else if (d_raw) begin
            d_addr = d_val[31:0];
            d_len  = d_val[95:64];
            d_act  = (d_len != 32'd0) ? 2'd1 : 2'd0;
        end else begin
            unique case (d_tag)
                PY_TAG_LONG_STR: begin
                    d_addr = d_val[31:0];
                    d_len  = 32'd16 + pad16({8'd0, d_val[119:96]});
                    if (mut_r == 8'd12) d_len = d_len - 32'd16;
                    d_act  = 2'd2;
                end
                PY_TAG_TUPLE: begin
                    if (d_val[127:64] != 64'd0) begin
                        d_addr = d_val[31:0];
                        d_size = d_val[95:64];
                        d_len  = d_val[95:64] << 5;
                        d_kind = K_TUPLE;
                        d_act  = 2'd3;
                        if (d_val[127:96] != 32'd0) d_wild = 1'b1;
                    end
                end
                PY_TAG_MUT_COLLEC: begin
                    d_addr = d_val[31:0];
                    d_act  = 2'd3;
                    unique case (mk)
                        PY_MUT_LIST:      begin d_kind = K_LIST; d_len = 32'd32; end
                        PY_MUT_DICT:      begin d_kind = K_DICT; d_len = 32'd48; end
                        PY_MUT_SET:       begin d_kind = K_SET;  d_len = 32'd32; end
                        PY_MUT_BYTEARRAY: begin d_kind = K_OBJ;  d_len = 32'd16; end
                        default: begin d_act = 2'd0; d_badkind = 1'b1; end
                    endcase
                end
                PY_TAG_OBJECT: begin
                    d_addr = d_val[31:0];
                    d_kind = K_OBJ;
                    d_len  = 32'd16;
                    d_act  = 2'd3;
                end
                PY_TAG_CODE_OBJECT: begin
                    if (!pycore_is_stracc_method_code(d_val[31:0])) begin
                        d_addr = d_val[31:0];
                        d_kind = K_CODE;
                        d_len  = PYCORE_CODE_OBJECT_BYTES;
                        d_act  = 2'd3;
                    end
                end
                PY_TAG_RANGE: begin
                    if (d_val[PYCORE_RANGE_MODE_BIT] && (mut_r != 8'd22)) begin
                        d_addr = d_val[31:0];
                        d_kind = K_TUPLE;
                        d_size = 32'd3;
                        d_len  = 32'd96;
                        d_act  = 2'd3;
                    end
                end
                PY_TAG_ITER: begin
                    if (d_val[127:120] != PY_ITER_MAGIC) begin
                        d_badkind = 1'b1;
                    end else begin
                        unique case (ik)
                            PY_ITER_KIND_LIST: begin
                                d_addr = ia; d_kind = K_LIST; d_len = 32'd32; d_act = 2'd3;
                            end
                            PY_ITER_KIND_TUPLE: begin
                                if (d_val[63:32] != 32'd0) begin
                                    d_addr = ia; d_kind = K_TUPLE; d_size = d_val[63:32];
                                    d_len = d_val[63:32] << 5; d_act = 2'd3;
                                end
                            end
                            PY_ITER_KIND_RANGE: ;
                            PY_ITER_KIND_STR: begin
                                // Empty SHORT_STR GET_ITER writes addr=0
                                // (no spill word). That is not a heap object.
                                // Mutant 43 (B13) decodes it as a LONG_STR.
                                if ((ia != 32'd0) || (mut_r == 8'd43)) begin
                                    d_addr = ia;
                                    if (d_val[96]) begin
                                        d_len = 32'd16;
                                        d_act = (mut_r == 8'd21) ? 2'd0 : 2'd2;
                                    end else begin
                                        d_kind = K_STR; d_len = 32'd16; d_act = 2'd3;
                                    end
                                end
                            end
                            PY_ITER_KIND_HEAP_ITER: begin
                                d_addr = ia; d_kind = K_OBJ; d_len = 32'd16; d_act = 2'd3;
                            end
                            PY_ITER_KIND_DICT: begin
                                d_addr = ia; d_kind = K_DICT; d_len = 32'd48; d_act = 2'd3;
                            end
                            PY_ITER_KIND_SET: begin
                                d_addr = ia; d_kind = K_SET; d_len = 32'd32; d_act = 2'd3;
                            end
                            default: d_badkind = 1'b1;
                        endcase
                    end
                end
                PY_TAG_BYTES, PY_TAG_FROZENSET: d_reserved = 1'b1;
                default: ;
            endcase
        end
        if (d_act != 2'd0) begin
            if ((d_addr[3:0] != 4'd0) || (d_addr < PYCORE_HEAP_BASE) ||
                (d_addr >= PYCORE_HEAP_LIMIT) || (d_len > (PYCORE_HEAP_LIMIT - d_addr))) begin
                d_wild = 1'b1;
            end
        end
        if (d_wild) d_act = 2'd0;
    end

    // First-word test/set from the decoded entry (valid in M_DEC).
    logic [31:0]  d_g, d_ge, d_ww, d_we;
    logic [6:0]   d_blo, d_bhi;
    logic [127:0] d_mask, d_bword;
    logic         d_marked, d_one_word;
    assign d_g    = d_addr >> 4;
    assign d_ge   = (d_len == 32'd0) ? d_g : ((d_addr + d_len - 32'd1) >> 4);
    assign d_ww   = d_g >> 7;
    assign d_we   = d_ge >> 7;
    assign d_blo  = d_g[6:0];
    assign d_bhi  = (d_ww == d_we) ? d_ge[6:0] : 7'd127;
    // Bits [d_blo, d_bhi] (empty when d_blo > d_bhi). Shift form, not a
    // 128-step loop: the simulator evaluates this every cycle.
    assign d_mask = ({128{1'b1}} << d_blo) & ({128{1'b1}} >> (7'd127 - d_bhi));
    assign d_bword   = bm_q[d_ww[BM_AW-1:0]];
    assign d_marked  = d_bword[d_blo];
    assign d_one_word = (d_ww == d_we);

    // Bitmap word / mask for the marker's granule cursor.
    logic [31:0]  m_w, m_w_end;
    logic [6:0]   m_b_lo, m_b_hi;
    logic [127:0] m_mask;
    logic [127:0] m_word;
    assign m_w     = m_g_r >> 7;
    assign m_w_end = m_g_end_r >> 7;
    assign m_b_lo  = m_g_r[6:0];
    assign m_b_hi  = (m_w == m_w_end) ? m_g_end_r[6:0] : 7'd127;
    assign m_mask = ({128{1'b1}} << m_b_lo) & ({128{1'b1}} >> (7'd127 - m_b_hi));
    assign m_word = bm_q[m_w[BM_AW-1:0]];

    // Sweep cursor.
    logic [31:0]  sw_g_r, sw_g_end_r, sw_run_start_r;
    logic         sw_free_r;
    logic         sw_pend_r;
    logic [31:0]  sw_pend_base_r, sw_pend_size_r;
    logic [31:0]  sw_wr_base_r, sw_wr_size_r, sw_wr_next_r, sw_wr_off_r;
    logic         sw_wr_busy_r;
    // Header-write queue so M_SW_SCAN keeps walking while a miss is in flight.
    // Depth 4 covers a typical mixed bitmap word (a few alignment-pad runs).
    logic [2:0]   swq_n_r;
    logic [31:0]  swq_base_r [0:3];
    logic [31:0]  swq_size_r [0:3];
    logic [31:0]  swq_next_r [0:3];
    logic [31:0]  swq_slot_r [0:3];
    logic [31:0]  sw_tbl_r, sw_pend_slot_r, sw_wr_slot_r;
    logic         sw_wr_hdr_r;
    logic         swq_hdr_r [0:3];
    logic [31:0]  run_base_q [0:RUN_ONCHIP-1];
    logic [31:0]  run_size_q [0:RUN_ONCHIP-1];
    logic [10:0]  run_onchip_n_r, run_rover_r;
    logic [31:0]  run_overflow_head_r;
    assign run_onchip_n_o      = {21'd0, run_onchip_n_r};
    assign run_rover_o         = {21'd0, run_rover_r};
    assign run_overflow_head_o = run_overflow_head_r;
    assign run_peek_base_o     = run_base_q[run_peek_idx_i];
    assign run_peek_size_o     = run_size_q[run_peek_idx_i];
    logic [31:0]  zero_base_r, dirty_hi_r;
    // Poison stops below zero_base_r: fresh memory must stay zero.
    logic [31:0]  sw_poison_lim;
    assign sw_poison_lim = (sw_wr_base_r + sw_wr_size_r <= zero_base_r) ? sw_wr_size_r
                         : (zero_base_r > sw_wr_base_r) ? (zero_base_r - sw_wr_base_r)
                         : 32'd16;
    assign dirty_hi_o = dirty_hi_r;
    logic [31:0]  sw_w;
    logic [6:0]   sw_b;
    logic [7:0]   sw_lim;      // exclusive bit limit in this word (1..128)
    logic [127:0] sw_word;
    logic         sw_found;
    logic [6:0]   sw_q;
    assign sw_w    = sw_g_r >> 7;
    assign sw_b    = sw_g_r[6:0];
    assign sw_word = bm_q[sw_w[BM_AW-1:0]];
    assign sw_lim  = (sw_w == ((sw_g_end_r - 32'd1) >> 7))
                     ? 8'(sw_g_end_r - (sw_w << 7)) : 8'd128;
    // First bit at or after sw_b (below sw_lim) that differs from sw_free_r's
    // "looking for" value: in a free run look for a 1, otherwise for a 0.
    // Candidates: bits in [sw_b, sw_lim) equal to sw_free_r; sw_q is the
    // lowest. Mask and one-hot encode instead of a 128-step loop.
    logic [127:0] sw_cand, sw_lsb;
    assign sw_cand = (sw_free_r ? sw_word : ~sw_word) & ({128{1'b1}} << sw_b) &
                     ((sw_lim[7]) ? {128{1'b1}} : ((128'd1 << sw_lim[6:0]) - 128'd1));
    assign sw_lsb  = sw_cand & (~sw_cand + 128'd1);
    always_comb begin
        sw_found = |sw_cand;
        sw_q[0] = |(sw_lsb & 128'haaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa);
        sw_q[1] = |(sw_lsb & 128'hcccccccccccccccccccccccccccccccc);
        sw_q[2] = |(sw_lsb & 128'hf0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0);
        sw_q[3] = |(sw_lsb & 128'hff00ff00ff00ff00ff00ff00ff00ff00);
        sw_q[4] = |(sw_lsb & 128'hffff0000ffff0000ffff0000ffff0000);
        sw_q[5] = |(sw_lsb & 128'hffffffff00000000ffffffff00000000);
        sw_q[6] = |(sw_lsb & 128'hffffffffffffffff0000000000000000);
    end

    // =====================================================================
    // Sequential logic
    // =====================================================================
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic          p1, p2, p3, sw_enq;
        logic [QW-1:0] i1, i2, i3;
        p1 = 1'b0; p2 = 1'b0; p3 = 1'b0; sw_enq = 1'b0;
        i1 = '0; i2 = '0; i3 = '0;
        if (rst_n_i) clean_done_r <= 1'b0;
        if (!rst_n_i) begin
            phase_r <= P_IDLE;
            dyn_base_r <= '0; heap_limit_r <= '0; spill_sp_r <= '0; exc_sp_r <= '0;
            keep_lo_r <= '0; keep_hi_r <= '0; keep_w_r <= '0; rover_addr_r <= '0;
            extra_roots_r <= 1'b0;
            frame_depth_r <= '0; stash_en_r <= 1'b0; poison_en_r <= 1'b0;
            stack_limit_r <= STACK_ENTRIES; onchip_limit_r <= 9'(MSTACK_ONCHIP);
            rescan_limit_r <= RESCAN_ENTRIES;
            resc_cnt_r <= '0; rescans_r <= '0; m_have_ent_r <= 1'b0; m_resc_done_r <= 1'b0;
            t_re_r <= '0;
            mut_r <= '0; bitmap_clean_r <= 1'b0; shadow_ok_r <= 1'b0;
            clean_busy_addr_r <= '0; clean_done_r <= 1'b0;
            out_r <= 1'b0; out_owner_r <= 1'b0;
            t_want_r <= 1'b0; t_line_r <= 1'b0; t_addr_r <= '0;
            m_want_r <= 1'b0; m_we_r <= 1'b0; m_addr_r <= '0; m_wdata_r <= '0; m_line_r <= 1'b0;
            q_rd_r <= '0; q_wr_r <= '0; q_cnt_r <= '0;
            tp_cnt_r <= '0;
            bot_r <= '0; cnt_r <= '0; mem_cnt_r <= '0; stack_hw_r <= '0;
            pop_give_r <= 1'b0; pop_ent_r <= '0; mark_done_r <= 1'b0;
            free_bytes_r <= '0; largest_base_r <= '0; largest_size_r <= '0;
            run_head_r <= '0; runs_r <= '0; overflow_r <= 1'b0; fault_r <= 1'b0;
            bad_kind_r <= '0; reserved_r <= '0; wild_r <= '0;
            mark_cyc_r <= '0; sweep_cyc_r <= '0; busy_mark_r <= '0; mark_xacts_r <= '0;
            spill_xacts_r <= '0; stash_cyc_r <= '0; objects_r <= '0; roots_r <= '0;
            stash_cnt_r <= '0; done_r <= 1'b0;
            t_st_r <= T_IDLE; t_mode_r <= SM_PLAIN; t_ptr_r <= '0; t_left_r <= '0;
            t_tag_r <= '0; t_cont_r <= 1'b0; t_cont_ptr_r <= '0; t_cont_left_r <= '0;
            t_range_r <= '0; t_ent_r <= '0; t_a_r <= '0; t_b_r <= '0;
            m_st_r <= M_IDLE; m_ent_r <= '0; m_g_r <= '0; m_g_end_r <= '0;
            m_push_r <= 1'b0; m_pent_r <= '0; m_clr_r <= '0; m_batch_r <= '0;
            m_clean_count_r <= '0; m_clean_idx_r <= '0;
            m_clean_word_r <= '0; m_clean_addr_r <= '0; m_clean_pyc_g_r <= '0;
            m_clean_builtins_r <= '0;
            m_clean_idle_r <= 1'b0;
            sw_g_r <= '0; sw_g_end_r <= '0; sw_run_start_r <= '0; sw_free_r <= 1'b0;
            sw_pend_r <= 1'b0; sw_pend_base_r <= '0; sw_pend_size_r <= '0;
            sw_wr_base_r <= '0; sw_wr_size_r <= '0; sw_wr_next_r <= '0; sw_wr_off_r <= '0;
            sw_wr_busy_r <= 1'b0;
            swq_n_r <= '0;
            sw_tbl_r <= PYCORE_GC_RUN_TABLE + (32'(RUN_ONCHIP) << 4);
            sw_pend_slot_r <= '0;
            sw_wr_slot_r <= '0;
            sw_wr_hdr_r <= 1'b1;
            run_onchip_n_r <= '0; run_rover_r <= '0;
            run_overflow_head_r <= '0;
            zero_base_r <= '0; dirty_hi_r <= '0;
            free_range_valid_o <= 1'b0; free_range_base_o <= '0; free_range_len_o <= '0;
        end else begin
            done_r <= 1'b0;
            pop_give_r <= 1'b0;
            free_range_valid_o <= 1'b0;

            // ---- port bookkeeping ----
            if (req_o) begin
                out_r <= 1'b1;
                out_owner_r <= grant_m;
                if (grant_t) begin
                    t_want_r <= 1'b0;
                    t_line_r <= 1'b0;
                end
                if (grant_m) begin
                    m_want_r <= 1'b0;
                    m_line_r <= 1'b0;
                end
                if ((phase_r == P_PRELOAD) || (phase_r == P_ROOTS_REG) ||
                    (phase_r == P_ROOTS_MEM) || (phase_r == P_MARK))
                    mark_xacts_r <= mark_xacts_r + 32'd1;
            end else if (ack_i && out_r) begin
                out_r <= 1'b0;
                if (fault_i) fault_r <= 1'b1;
            end
            if ((phase_r == P_PRELOAD) || (phase_r == P_ROOTS_REG) ||
                (phase_r == P_ROOTS_MEM) || (phase_r == P_MARK)) begin
                mark_cyc_r <= mark_cyc_r + 32'd1;
                if (out_r || req_o) busy_mark_r <= busy_mark_r + 32'd1;
            end
            if (phase_r == P_SWEEP) sweep_cyc_r <= sweep_cyc_r + 32'd1;
            if (stack_total > stack_hw_r) stack_hw_r <= stack_total;

            // ---- queue push/pop ----
            if (q_push) begin
                q_mem[q_wr_r] <= q_din;
                q_wr_r <= q_wr_r + 2'd1;
            end
            if (q_pop) q_rd_r <= q_rd_r + 2'd1;
            q_cnt_r <= q_cnt_r + (q_push ? 3'd1 : 3'd0) - (q_pop ? 3'd1 : 3'd0);

            // ---- start ----
            if ((phase_r == P_IDLE) && start_i) begin
                dyn_base_r    <= dyn_base_i;
                heap_limit_r  <= heap_limit_i;
                keep_lo_r     <= keep_lo_i;
                rover_addr_r  <= rover_addr_i;
                extra_roots_r <= extra_roots_i;
                keep_hi_r     <= (keep_hi_i > keep_lo_i) ? keep_hi_i : keep_lo_i;
                spill_sp_r    <= spill_sp_i;
                exc_sp_r      <= exc_sp_i;
                frame_depth_r <= frame_depth_i;
                stash_en_r    <= stash_en_i;
                poison_en_r   <= poison_en_i;
                zero_base_r   <= zero_base_i;
                dirty_hi_r    <= 32'd0;
                stack_limit_r <= (stack_limit_i == 32'd0 || stack_limit_i > STACK_ENTRIES)
                                 ? STACK_ENTRIES : stack_limit_i;
                onchip_limit_r <= ((onchip_limit_i == 8'd0) || (9'(onchip_limit_i) > 9'(MSTACK_ONCHIP)))
                                  ? 9'(MSTACK_ONCHIP) : 9'(onchip_limit_i);
                rescan_limit_r <= (rescan_limit_i == 32'd0 || rescan_limit_i > RESCAN_ENTRIES)
                                  ? RESCAN_ENTRIES : rescan_limit_i;
                resc_cnt_r <= '0; rescans_r <= '0;
                m_have_ent_r <= 1'b0; m_resc_done_r <= 1'b0;
                mut_r         <= mutant_i;
                free_bytes_r <= '0; largest_base_r <= '0; largest_size_r <= '0;
                run_head_r <= '0; runs_r <= '0; overflow_r <= 1'b0; fault_r <= 1'b0;
                run_onchip_n_r <= '0; run_overflow_head_r <= '0; run_rover_r <= '0;
                bad_kind_r <= '0; reserved_r <= '0; wild_r <= '0;
                mark_cyc_r <= '0; sweep_cyc_r <= '0; busy_mark_r <= '0; mark_xacts_r <= '0;
                spill_xacts_r <= '0; stash_cyc_r <= '0; objects_r <= '0; roots_r <= '0;
                stash_cnt_r <= '0; stack_hw_r <= '0; mark_done_r <= 1'b0;
                bot_r <= '0; cnt_r <= '0; mem_cnt_r <= '0;
                m_clr_r <= '0;
                m_clean_count_r <= '0;
                m_clean_idx_r <= '0;
                m_clean_idle_r <= 1'b0;
                if (bitmap_clean_r) begin
                    phase_r <= P_CLEANUP;
                    m_st_r  <= M_CLEAN_HDR;
                end else begin
                    phase_r <= P_CLEAR;
                    m_st_r  <= M_CLEAR;
                end
            end
            if ((phase_r == P_ROOTS_REG) && roots_done_i && !root_valid_i) begin
                phase_r   <= P_ROOTS_MEM;
                t_st_r    <= T_MEMROOT;
                t_range_r <= 4'd0;
            end
            if (root_take) roots_r <= roots_r + 32'd1;

            // =============================================================
            // Tracer FSM
            // =============================================================
            unique case (t_st_r)
                T_IDLE: ;

                // Pick the next memory-root range.
                T_MEMROOT: begin
                    t_mode_r <= SM_PLAIN;
                    t_cont_r <= 1'b0;
                    t_st_r   <= T_SCAN;
                    unique case (t_range_r)
                        4'd0: begin // boot record: 3 tagged pairs
                            t_ptr_r <= PYCORE_BOOT_RECORD_ADDR;
                            t_left_r <= (mut_r == 8'd9) ? 32'd0 : 32'd3;
                        end
                        4'd1: begin // native-method sidecar
                            t_ptr_r <= PYCORE_NATIVE_METHOD_TABLE_ADDR;
                            t_left_r <= (mut_r == 8'd10) ? 32'd0 : PYCORE_NATIVE_METHOD_COUNT;
                        end
                        4'd2: begin // StopIteration sidecar
                            t_ptr_r <= PYCORE_ITER_EXHAUST_TYPE_ADDR;
                            t_left_r <= 32'd1;
                        end
                        4'd3: begin // preallocated MemoryError singleton
                            t_ptr_r <= PYCORE_MEMORY_ERROR_INSTANCE_ADDR;
                            t_left_r <= 32'd1;
                        end
                        4'd4: begin // RF spill prefix
                            t_ptr_r <= PYCORE_RF_SPILL_BASE;
                            t_left_r <= (mut_r == 8'd2) ? 32'd0
                                        : ((spill_sp_r - PYCORE_RF_SPILL_BASE) >> 5);
                        end
                        4'd5: begin // exception stack
                            t_mode_r <= SM_EXC;
                            t_ptr_r <= PYCORE_EXC_STACK_BASE;
                            t_left_r <= (mut_r == 8'd5) ? 32'd0
                                        : ((exc_sp_r - PYCORE_EXC_STACK_BASE) >> 5);
                        end
                        4'd6: begin // frame descriptors
                            t_mode_r <= SM_FRAME;
                            t_ptr_r <= PYCORE_FRAME_STACK_BASE;
                            t_left_r <= (mut_r == 8'd3) ? 32'd0 : frame_depth_r;
                        end
                        4'd7: begin // builtins values the prune map keeps
                            t_ptr_r <= PYCORE_GC_EXTRA_ROOTS;
                            t_left_r <= extra_roots_r ? PYCORE_GC_EXTRA_ROOTS_COUNT : 32'd0;
                        end
                        default: begin
                            t_st_r  <= T_POP;
                            phase_r <= P_MARK;
                        end
                    endcase
                    t_range_r <= t_range_r + 4'd1;
                end

                // Issue the read for the next element of the current scan.
                T_SCAN: begin
                    if (t_left_r == 32'd0) begin
                        if (t_cont_r) begin
                            // Dict table after the order buffer: a new range.
                            // Switch once no order-buffer child can still
                            // overflow against it (or all have drained); a
                            // continuation push needs the pending buffer empty.
                            if (((m_st_r == M_IDLE) && (q_cnt_r == 3'd0) && (tp_cnt_r == 2'd0)) ||
                                (!m_resc_done_r && stk_room8 && (t_cont_left_r <= SCAN_CHUNK))) begin
                                t_cont_r <= 1'b0;
                                t_mode_r <= SM_DICTT;
                                t_ptr_r  <= t_cont_ptr_r;
                                t_left_r <= chunk(t_cont_left_r);
                                t_re_r   <= {K_DICTT, chunk(t_cont_left_r), t_cont_ptr_r};
                                m_resc_done_r <= 1'b0;
                                if (t_cont_left_r > SCAN_CHUNK) begin
                                    p1 = 1'b1;
                                    i1 = qcont(K_DICTT, t_cont_left_r - SCAN_CHUNK,
                                               t_cont_ptr_r + (SCAN_CHUNK << 6));
                                end
                            end
                        end else if (phase_r == P_ROOTS_MEM) begin
                            t_st_r <= T_MEMROOT;
                        end else begin
                            t_st_r <= T_POP;
                        end
                    end else if (!t_want_r && (tp_cnt_r == 2'd0 ||
                               (t_mode_r != SM_FRAME && tp_cnt_r < 2'd3))) begin
                        if (cache_en_i && (t_ptr_r[5:0] == 6'd0) &&
                            (tp_cnt_r < 2'd2) &&
                            (((t_mode_r == SM_PLAIN) && (t_left_r >= 32'd2)) ||
                             ((t_mode_r == SM_DICTT) && (t_left_r >= 32'd1)))) begin
                            t_want_r <= 1'b1;
                            t_line_r <= 1'b0;
                            t_addr_r <= t_ptr_r + 32'd16;
                            t_st_r   <= T_LINE_W;
                        end else begin
                            t_want_r <= 1'b1;
                            t_line_r <= 1'b0;
                            t_addr_r <= t_ptr_r + 32'd16;
                            t_st_r   <= T_TAG_W;
                        end
                    end
                end

                // Tag (or packed slot1) of the current element.
                T_TAG_W: begin
                    if (t_ack) begin
                        unique case (t_mode_r)
                            SM_PLAIN, SM_DICTT: begin
                                logic [3:0] tg;
                                logic skip_slot;
                                tg = rdata_i[3:0];
                                skip_slot = (t_mode_r == SM_DICTT) &&
                                            (pycore_dict_slot_empty(rdata_i) ||
                                             ((tg == PY_TAG_TOMBSTONE) && (mut_r != 8'd16)) ||
                                             ((mut_r == 8'd17) && (tg == PY_TAG_CONTROL)));
                                if (is_reserved_tag(tg) && !skip_slot)
                                    reserved_r <= reserved_r + 32'd1;
                                t_tag_r <= tg;
                                if (skip_slot) begin
                                    t_ptr_r  <= t_ptr_r + 32'd64;
                                    t_left_r <= t_left_r - 32'd1;
                                    t_st_r   <= T_SCAN;
                                end else if (is_ptr_tag(tg)) begin
                                    // The value ack pushes one item: issue now
                                    // only if the pending buffer has room.
                                    if (tp_cnt_r < 2'd3) begin
                                        t_want_r <= 1'b1;
                                        t_addr_r <= t_ptr_r;
                                        t_st_r   <= T_VAL_W;
                                    end else begin
                                        t_st_r   <= T_VAL_ISSUE;
                                    end
                                end else if (t_mode_r == SM_DICTT) begin
                                    t_want_r <= 1'b1;
                                    t_addr_r <= t_ptr_r + 32'd48;
                                    t_st_r   <= T_VTAG_W;
                                end else begin
                                    // Non-pointer: issue the next tag read now.
                                    t_ptr_r  <= t_ptr_r + 32'd32;
                                    t_left_r <= t_left_r - 32'd1;
                                    if (t_left_r > 32'd1) begin
                                        t_want_r <= 1'b1;
                                        t_addr_r <= t_ptr_r + 32'd48;
                                        t_st_r   <= T_TAG_W;
                                    end else begin
                                        t_st_r <= T_SCAN;
                                    end
                                end
                            end
                            SM_EXC: begin
                                if (rdata_i[127] &&
                                    ((rdata_i[123:120] == PY_TAG_OBJECT) ||
                                     (rdata_i[123:120] == PY_TAG_CODE_OBJECT))) begin
                                    p1 = 1'b1;
                                    i1 = qhandle(rdata_i[123:120], {64'd0, rdata_i[63:0]});
                                end else if (rdata_i[127] &&
                                             (rdata_i[123:120] != PY_TAG_CONTROL)) begin
                                    bad_kind_r <= bad_kind_r + 32'd1;
`ifndef SYNTHESIS
                                    if ($test$plusargs("GC_TRACE_DEC"))
                                        $display("[GC-DEC] exc bad_kind tag=%0h word=%h",
                                                 rdata_i[123:120], rdata_i);
`endif
                                end
                                t_ptr_r  <= t_ptr_r + 32'd32;
                                t_left_r <= t_left_r - 32'd1;
                                t_st_r   <= T_SCAN;
                            end
                            default: begin // SM_FRAME
                                if (rdata_i[31:0] != 32'd0) begin
                                    p1 = 1'b1;
                                    i1 = qhandle(PY_TAG_CODE_OBJECT, {96'd0, rdata_i[31:0]});
                                end
                                if (rdata_i[96:33] != 64'd0) begin
                                    p2 = 1'b1;
                                    i2 = qhandle(PY_TAG_OBJECT, {64'd0, rdata_i[96:33]});
                                end
                                if ((rdata_i[127:97] != 31'd0) && (mut_r != 8'd4)) begin
                                    p3 = 1'b1;
                                    i3 = qhandle(PY_TAG_MUT_COLLEC,
                                        pycore_mut_value(PY_MUT_DICT, {33'd0, rdata_i[127:97]}, 1'b0));
                                end
                                t_ptr_r  <= t_ptr_r + 32'd32;
                                t_left_r <= t_left_r - 32'd1;
                                t_st_r   <= T_SCAN;
                            end
                        endcase
                    end
                end

                // Value of a pointer element (PLAIN) or dict key (DICTT).
                T_VAL_W: begin
                    if (t_ack) begin
                        p1 = 1'b1;
                        i1 = qhandle(t_tag_r, rdata_i);
                        if (t_mode_r == SM_DICTT) begin
                            t_want_r <= 1'b1;
                            t_addr_r <= t_ptr_r + 32'd48;
                            t_st_r   <= T_VTAG_W;
                        end else begin
                            t_ptr_r  <= t_ptr_r + 32'd32;
                            t_left_r <= t_left_r - 32'd1;
                            if (t_left_r > 32'd1) begin
                                t_want_r <= 1'b1;
                                t_addr_r <= t_ptr_r + 32'd48;
                                t_st_r   <= T_TAG_W;
                            end else begin
                                t_st_r <= T_SCAN;
                            end
                        end
                    end
                end

                // Dict value tag / value.
                T_VTAG_W: begin
                    if (t_ack) begin
                        t_tag_r <= rdata_i[3:0];
                        if (is_reserved_tag(rdata_i[3:0])) reserved_r <= reserved_r + 32'd1;
                        if (is_ptr_tag(rdata_i[3:0])) begin
                            if (tp_cnt_r < 2'd3) begin
                                t_want_r <= 1'b1;
                                t_addr_r <= t_ptr_r + 32'd32;
                                t_st_r   <= T_VVAL_W;
                            end else begin
                                t_st_r   <= T_VVAL_ISSUE;
                            end
                        end else begin
                            t_ptr_r  <= t_ptr_r + 32'd64;
                            t_left_r <= t_left_r - 32'd1;
                            t_st_r   <= T_SCAN;
                        end
                    end
                end
                T_VVAL_W: begin
                    if (t_ack) begin
                        p1 = 1'b1;
                        i1 = qhandle(t_tag_r, rdata_i);
                        t_ptr_r  <= t_ptr_r + 32'd64;
                        t_left_r <= t_left_r - 32'd1;
                        t_st_r   <= T_SCAN;
                    end
                end

                // Pop the next object and start its traversal.
                T_POP: begin
                    if (mark_done_r) begin
                        t_st_r <= T_DONE;
                    end else if (pop_give_r) begin
                        t_ent_r   <= pop_ent_r;
                        objects_r <= objects_r + 32'd1;
`ifndef SYNTHESIS
                        if ($test$plusargs("GC_TRACE_OBJS"))
                            $display("[GC-OBJ] n=%0d kind=%0d addr=%h size=%0d",
                                     objects_r + 32'd1, pop_ent_r[66:64],
                                     pop_ent_r[31:0], pop_ent_r[63:32]);
`endif
                        t_mode_r  <= SM_PLAIN;
                        t_cont_r  <= 1'b0;
                        t_re_r    <= pop_ent_r;
                        unique case (pop_ent_r[66:64])
                            K_TUPLE: begin
                                // The pending buffer is empty at a pop, so the
                                // continuation and a line ack's two items fit.
                                t_ptr_r  <= pop_ent_r[31:0];
                                t_left_r <= chunk(pop_ent_r[63:32]);
                                t_re_r   <= {K_TUPLE, chunk(pop_ent_r[63:32]), pop_ent_r[31:0]};
                                if (pop_ent_r[63:32] > SCAN_CHUNK) begin
                                    p1 = 1'b1;
                                    i1 = qcont(K_TUPLE, pop_ent_r[63:32] - SCAN_CHUNK,
                                               pop_ent_r[31:0] + (SCAN_CHUNK << 5));
                                end
                                if (cache_en_i && (pop_ent_r[5:0] == 6'd0) &&
                                    (pop_ent_r[63:32] >= 32'd2) && (tp_cnt_r < 2'd2)) begin
                                    t_want_r <= 1'b1;
                                    t_line_r <= 1'b0;
                                    t_addr_r <= pop_ent_r[31:0] + 32'd16;
                                    t_st_r   <= T_LINE_W;
                                end else begin
                                    t_st_r   <= T_SCAN;
                                end
                            end
                            K_CODE: begin
                                logic [31:0] cptr, cleft;
                                cptr  = (mut_r == 8'd20)
                                        ? (pop_ent_r[31:0] + 32'd64)
                                        : pop_ent_r[31:0];
                                cleft = (mut_r == 8'd20)
                                        ? (PYCORE_CODE_NFIELDS - 32'd2)
                                        : PYCORE_CODE_NFIELDS;
                                t_ptr_r  <= cptr;
                                t_left_r <= cleft;
                                if (cache_en_i && (cptr[5:0] == 6'd0) &&
                                    (cleft >= 32'd2) && (tp_cnt_r < 2'd2)) begin
                                    t_want_r <= 1'b1;
                                    t_line_r <= 1'b0;
                                    t_addr_r <= cptr + 32'd16;
                                    t_st_r   <= T_LINE_W;
                                end else begin
                                    t_st_r   <= T_SCAN;
                                end
                            end
                            K_DICTT: begin
                                t_mode_r <= SM_DICTT;
                                t_ptr_r  <= pop_ent_r[31:0];
                                t_left_r <= chunk(pop_ent_r[63:32]);
                                t_re_r   <= {K_DICTT, chunk(pop_ent_r[63:32]), pop_ent_r[31:0]};
                                if (pop_ent_r[63:32] > SCAN_CHUNK) begin
                                    p1 = 1'b1;
                                    i1 = qcont(K_DICTT, pop_ent_r[63:32] - SCAN_CHUNK,
                                               pop_ent_r[31:0] + (SCAN_CHUNK << 6));
                                end
                                t_st_r   <= T_SCAN;
                            end
                            default: begin
                                // LIST / DICT / SET / OBJ / STR: header first.
                                // LIST/SET headers are 32 B; one word read
                                // returns the line unless the object starts
                                // at line offset 48.
                                if (cache_en_i &&
                                    ((pop_ent_r[66:64] == K_LIST) ||
                                     (pop_ent_r[66:64] == K_SET)) &&
                                    (pop_ent_r[5:0] != 6'd48)) begin
                                    t_want_r <= 1'b1;
                                    t_line_r <= 1'b0;
                                    t_addr_r <= pop_ent_r[31:0] + 32'd16;
                                    t_st_r   <= T_HDR_LINE_W;
                                end else begin
                                    t_want_r <= 1'b1;
                                    t_addr_r <= pop_ent_r[31:0];
                                    t_st_r   <= T_HDR_W;
                                end
                            end
                        endcase
                    end
                end

                // First header word.
                T_HDR_W: begin
                    if (t_ack) begin
                        unique case (t_kind)
                            K_LIST: begin
                                t_a_r <= rdata_i[95:64];   // capacity
                                t_b_r <= rdata_i[31:0];    // length
                                if (rdata_i[63:0] > rdata_i[127:64]) begin
                                    bad_kind_r <= bad_kind_r + 32'd1;
`ifndef SYNTHESIS
                                    if ($test$plusargs("GC_TRACE_DEC"))
                                        $display("[GC-DEC] LIST len>cap at %h hdr=%h",
                                                 t_eaddr, rdata_i);
`endif
                                end
                                t_want_r <= 1'b1;
                                t_addr_r <= t_eaddr + 32'd16;
                                t_st_r   <= T_HDR2_W;
                            end
                            K_SET, K_DICT: begin
                                t_a_r <= rdata_i[95:64];   // slot count
                                t_want_r <= 1'b1;
                                t_addr_r <= t_eaddr + 32'd16;
                                t_st_r   <= T_HDR2_W;
                            end
                            K_STR: begin
                                p1 = 1'b1;
                                i1 = qraw(t_eaddr, 32'd16 + pad16({8'd0, rdata_i[119:96]}));
                                t_st_r <= T_POP;
                            end
                            default: begin // K_OBJ
                                logic [31:0] ext;
                                ext = obj_extent(rdata_i[127:96]);
                                if (ext == 32'd0) begin
                                    bad_kind_r <= bad_kind_r + 32'd1;
`ifndef SYNTHESIS
                                    if ($test$plusargs("GC_TRACE_DEC"))
                                        $display("[GC-DEC] OBJ bad_kind at %h hdr=%h",
                                                 t_eaddr, rdata_i);
`endif
                                    t_st_r <= T_POP;
                                end else begin
                                    p1 = 1'b1;
                                    i1 = qraw(t_eaddr, ext);
                                    if ((rdata_i[63:0] != 64'd0) && (mut_r != 8'd19)) begin
                                        p2 = 1'b1;
                                        i2 = qhandle(PY_TAG_OBJECT, {64'd0, rdata_i[63:0]});
                                    end
                                    if (rdata_i[127:96] == PY_OBK_BYTEARRAY) begin
                                        t_want_r <= 1'b1;
                                        t_addr_r <= pycore_obj_field_val_addr(t_eaddr, 32'd1);
                                        t_st_r   <= T_BA_BUF_W;
                                    end else begin
                                        t_ptr_r  <= t_eaddr + 32'd32;
                                        t_left_r <= (ext - 32'd32) >> 5;
                                        t_st_r   <= T_SCAN;
                                    end
                                end
                            end
                        endcase
                    end
                end

                // Second header word: list ob_item / set table / dict meta.
                T_HDR2_W: begin
                    if (t_ack) begin
                        unique case (t_kind)
                            K_LIST: begin
                                logic [31:0] nl;
                                nl = ((mut_r == 8'd13) && (t_b_r != 32'd0)) ? (t_b_r - 32'd1) : t_b_r;
                                if ((t_a_r != 32'd0) && (rdata_i[31:0] != 32'd0)) begin
                                    p1 = 1'b1;
                                    i1 = qraw(rdata_i[31:0],
                                                       (mut_r == 8'd14) ? (t_b_r << 5) : (t_a_r << 5));
                                end
                                if (nl > SCAN_CHUNK) begin
                                    p2 = 1'b1;
                                    i2 = qcont(K_TUPLE, nl - SCAN_CHUNK,
                                               rdata_i[31:0] + (SCAN_CHUNK << 5));
                                end
                                t_ptr_r  <= rdata_i[31:0];
                                t_left_r <= chunk(nl);
                                t_re_r   <= {K_TUPLE, chunk(nl), rdata_i[31:0]};
                                t_st_r   <= T_SCAN;
                            end
                            K_SET: begin
                                if ((t_a_r != 32'd0) && (rdata_i[31:0] != 32'd0)) begin
                                    if (mut_r != 8'd18) begin
                                        p1 = 1'b1;
                                        i1 = qraw(rdata_i[31:0], t_a_r << 5);
                                    end
                                    if (t_a_r > SCAN_CHUNK) begin
                                        p2 = 1'b1;
                                        i2 = qcont(K_TUPLE, t_a_r - SCAN_CHUNK,
                                                   rdata_i[31:0] + (SCAN_CHUNK << 5));
                                    end
                                    t_ptr_r  <= rdata_i[31:0];
                                    t_left_r <= chunk(t_a_r);
                                    t_re_r   <= {K_TUPLE, chunk(t_a_r), rdata_i[31:0]};
                                end else begin
                                    t_left_r <= 32'd0;
                                end
                                t_st_r <= T_SCAN;
                            end
                            default: begin // K_DICT: meta {version, order_len}
                                t_b_r <= rdata_i[31:0];    // order_len
                                t_want_r <= 1'b1;
                                t_addr_r <= t_eaddr + 32'd32;
                                t_st_r   <= T_HDR3_W;
                            end
                        endcase
                    end
                end

                // Dict pointer word {order_ptr, table_ptr}.
                T_HDR3_W: begin
                    if (t_ack) begin
                        if ((t_a_r != 32'd0) && (rdata_i[95:64] != 32'd0) && (mut_r != 8'd15)) begin
                            p1 = 1'b1;
                            i1 = qraw(rdata_i[95:64], t_a_r << 5);
                        end
                        if ((t_a_r != 32'd0) && (rdata_i[31:0] != 32'd0)) begin
                            p2 = 1'b1;
                            i2 = qraw(rdata_i[31:0], t_a_r << 6);
                            t_cont_r      <= 1'b1;
                            t_cont_ptr_r  <= rdata_i[31:0];
                            t_cont_left_r <= t_a_r;
                        end
                        if ((rdata_i[95:64] != 32'd0) && (t_b_r > SCAN_CHUNK)) begin
                            p3 = 1'b1;
                            i3 = qcont(K_TUPLE, t_b_r - SCAN_CHUNK,
                                       rdata_i[95:64] + (SCAN_CHUNK << 5));
                        end
                        t_ptr_r  <= rdata_i[95:64];
                        t_left_r <= (rdata_i[95:64] != 32'd0) ? chunk(t_b_r) : 32'd0;
                        t_re_r   <= {K_TUPLE, chunk(t_b_r), rdata_i[95:64]};
                        t_st_r   <= T_SCAN;
                    end
                end

                // Bytearray: field1 buf_addr, field2 capacity (INT-tagged).
                T_BA_BUF_W: begin
                    if (t_ack) begin
                        t_a_r    <= rdata_i[31:0];
                        t_want_r <= 1'b1;
                        t_addr_r <= pycore_obj_field_val_addr(t_eaddr, 32'd2);
                        t_st_r   <= T_BA_CAP_W;
                    end
                end
                T_BA_CAP_W: begin
                    if (t_ack) begin
                        if ((t_a_r != 32'd0) && (rdata_i[31:0] != 32'd0) && (mut_r != 8'd23)) begin
                            p1 = 1'b1;
                            i1 = qraw(t_a_r, pad16(rdata_i[31:0]));
                        end
                        t_st_r <= T_POP;
                    end
                end

                // Value reads deferred until the pending buffer has room.
                T_VAL_ISSUE: begin
                    if (tp_cnt_r < 2'd3) begin
                        t_want_r <= 1'b1;
                        t_addr_r <= t_ptr_r;
                        t_st_r   <= T_VAL_W;
                    end
                end
                T_VVAL_ISSUE: begin
                    if (tp_cnt_r < 2'd3) begin
                        t_want_r <= 1'b1;
                        t_addr_r <= t_ptr_r + 32'd32;
                        t_st_r   <= T_VVAL_W;
                    end
                end

                T_LINE_W: begin
                    if (t_ack) begin
                        logic [3:0]   tg0, tg1;
                        logic [127:0] v0, v1, ktagw;
                        logic         skip_slot;
                        v0    = rline_i[127:0];
                        ktagw = rline_i[255:128];
                        tg0   = ktagw[3:0];
                        v1    = rline_i[383:256];
                        tg1   = rline_i[387:384];
                        skip_slot = (t_mode_r == SM_DICTT) &&
                                    (pycore_dict_slot_empty(ktagw) ||
                                     ((tg0 == PY_TAG_TOMBSTONE) && (mut_r != 8'd16)) ||
                                     ((mut_r == 8'd17) && (tg0 == PY_TAG_CONTROL)));
                        if (!skip_slot) begin
                            if (is_reserved_tag(tg0)) reserved_r <= reserved_r + 32'd1;
                            if (is_reserved_tag(tg1)) reserved_r <= reserved_r + 32'd1;
                            if (is_ptr_tag(tg0)) begin
                                p1 = 1'b1;
                                i1 = qhandle(tg0, v0);
                            end
                            if (is_ptr_tag(tg1)) begin
                                p2 = 1'b1;
                                i2 = qhandle(tg1, v1);
                            end
                        end
                        t_ptr_r  <= t_ptr_r + 32'd64;
                        t_left_r <= t_left_r - ((t_mode_r == SM_DICTT) ? 32'd1 : 32'd2);
                        if ((t_left_r <= ((t_mode_r == SM_DICTT) ? 32'd1 : 32'd2))
                            && !t_cont_r) begin
                            if (phase_r == P_ROOTS_MEM)
                                t_st_r <= T_MEMROOT;
                            else
                                t_st_r <= T_POP;
                        end else begin
                            t_st_r <= T_SCAN;
                        end
                    end
                end

                T_HDR_LINE_W: begin
                    if (t_ack) begin
                        logic [127:0] w0, w1;
                        logic [31:0]  item, leftn;
                        unique case (t_eaddr[5:0])
                            6'd0:  begin w0 = rline_i[127:0];   w1 = rline_i[255:128]; end
                            6'd16: begin w0 = rline_i[255:128]; w1 = rline_i[383:256]; end
                            6'd32: begin w0 = rline_i[383:256]; w1 = rline_i[511:384]; end
                            default: begin w0 = rdata_i; w1 = '0; end
                        endcase
                        t_a_r <= w0[95:64];
                        t_b_r <= w0[31:0];
                        if (t_kind == K_LIST) begin
                            if (w0[63:0] > w0[127:64]) begin
                                bad_kind_r <= bad_kind_r + 32'd1;
`ifndef SYNTHESIS
                                if ($test$plusargs("GC_TRACE_DEC"))
                                    $display("[GC-DEC] LIST len>cap at %h hdr=%h",
                                             t_eaddr, w0);
`endif
                            end
                            item  = w1[31:0];
                            leftn = ((mut_r == 8'd13) && (w0[31:0] != 32'd0))
                                    ? (w0[31:0] - 32'd1) : w0[31:0];
                            if ((w0[95:64] != 32'd0) && (item != 32'd0)) begin
                                p1 = 1'b1;
                                i1 = qraw(item, (mut_r == 8'd14)
                                          ? (w0[31:0] << 5) : (w0[95:64] << 5));
                            end
                            if (leftn > SCAN_CHUNK) begin
                                p2 = 1'b1;
                                i2 = qcont(K_TUPLE, leftn - SCAN_CHUNK, item + (SCAN_CHUNK << 5));
                            end
                            t_ptr_r  <= item;
                            t_left_r <= chunk(leftn);
                            t_re_r   <= {K_TUPLE, chunk(leftn), item};
                            // With a continuation queued, T_SCAN issues the
                            // line read once the pending buffer has room.
                            if (cache_en_i && (item[5:0] == 6'd0) && (leftn <= SCAN_CHUNK) &&
                                (leftn >= 32'd2) && (tp_cnt_r < 2'd2)) begin
                                t_want_r <= 1'b1;
                                t_line_r <= 1'b0;
                                t_addr_r <= item + 32'd16;
                                t_st_r   <= T_LINE_W;
                            end else begin
                                t_st_r <= T_SCAN;
                            end
                        end else begin // K_SET
                            item = w1[31:0];
                            if ((w0[95:64] != 32'd0) && (item != 32'd0)) begin
                                if (mut_r != 8'd18) begin
                                    p1 = 1'b1;
                                    i1 = qraw(item, w0[95:64] << 5);
                                end
                                if (w0[95:64] > SCAN_CHUNK) begin
                                    p2 = 1'b1;
                                    i2 = qcont(K_TUPLE, w0[95:64] - SCAN_CHUNK,
                                               item + (SCAN_CHUNK << 5));
                                end
                                t_ptr_r  <= item;
                                t_left_r <= chunk(w0[95:64]);
                                t_re_r   <= {K_TUPLE, chunk(w0[95:64]), item};
                            end else begin
                                t_left_r <= 32'd0;
                            end
                            t_st_r <= T_SCAN;
                        end
                    end
                end

                T_DONE: ;
                default: t_st_r <= T_IDLE;
            endcase

            // =============================================================
            // Marker FSM
            // =============================================================
            unique case (m_st_r)
                M_IDLE: begin
                    if (q_cnt_r != 3'd0) begin
                        m_ent_r <= q_dout;
                        m_st_r  <= (q_dout[133] && stash_en_r) ? M_STASH_V : M_DEC;
                    end else if ((phase_r == P_MARK) && pop_req && !pop_give_r &&
                                 (tp_cnt_r == 2'd0)) begin
                        if (cnt_r != '0) begin
                            pop_ent_r  <= ring[OC_AW'(bot_r + OC_AW'(cnt_r) - OC_AW'(1))];
                            cnt_r      <= cnt_r - 1'b1;
                            pop_give_r <= 1'b1;
                            // Nothing is in flight: the next scan starts clean.
                            m_have_ent_r  <= 1'b1;
                            m_resc_done_r <= 1'b0;
                        end else if (mem_cnt_r != 32'd0) begin
                            m_batch_r <= 6'd0;
                            m_st_r    <= M_REFILL;
                        end else if (resc_cnt_r != 32'd0) begin
                            m_st_r    <= M_RESC_RD;
                        end else begin
                            mark_done_r <= 1'b1;
                            phase_r     <= P_SWEEP;
                            m_clr_r     <= 32'd0;
                            m_st_r      <= (keep_hi_r > keep_lo_r) ? M_SW_KEEP : M_SW_PRE;
                            keep_w_r    <= keep_lo_r >> 11;
                            sw_g_end_r  <= heap_limit_r >> 4;
                            sw_g_r      <= dyn_base_r >> 4;
                            sw_free_r   <= 1'b0;
                            sw_pend_r   <= 1'b0;
                            sw_wr_busy_r <= 1'b0;
                            swq_n_r     <= '0;
                            sw_tbl_r    <= PYCORE_GC_RUN_TABLE + (32'(RUN_ONCHIP) << 4);
                            run_onchip_n_r      <= '0;
                            run_rover_r         <= '0;
                            run_overflow_head_r <= '0;
                        end
                    end
                end

                M_CLEAR: begin
                    bm_q[m_clr_r[BM_AW-1:0]] <= '0;
                    if (m_clr_r == 32'(BM_WORDS - 1)) begin
                        bitmap_clean_r <= 1'b1;
                        phase_r <= P_CLEANUP;
                        m_st_r  <= M_CLEAN_HDR;
                        m_clr_r <= 32'd0;
                    end else begin
                        m_clr_r <= m_clr_r + 32'd1;
                    end
                end

                // An image may describe reference-valued compiler scratch
                // slots in the _PYC_G dictionary.  If compile() is idle,
                // replace each value/tag pair with INT 0 before root tracing.
                // This keeps the GC_EN=0 instruction stream unchanged while
                // making compiler arenas collectible at the next collection.
                M_CLEAN_HDR: begin
                    m_want_r <= 1'b1;
                    m_we_r   <= 1'b0;
                    m_addr_r <= PYCORE_GC_COMPILER_CLEANUP;
                    m_st_r   <= M_CLEAN_HDR_W;
                end
                M_CLEAN_HDR_W: begin
                    if (m_ack) begin
                        if ((rdata_i[127:96] == PYCORE_GC_COMPILER_CLEANUP_MAGIC) &&
                            (rdata_i[95:64] != 32'd0) &&
                            (rdata_i[95:64] <= 32'd188) &&
                            (rdata_i[63:32] >= PYCORE_HEAP_BASE) &&
                            (rdata_i[63:32] + 32'd16 < dyn_base_r) &&
                            ({16'd0, rdata_i[15:0], 4'd0} >= PYCORE_HEAP_BASE) &&
                            ({16'd0, rdata_i[15:0], 4'd0} < dyn_base_r) &&
                            ((rdata_i[31:16] == 16'd0) ||
                             (({16'd0, rdata_i[31:16], 4'd0} >= PYCORE_HEAP_BASE) &&
                              ({16'd0, rdata_i[31:16], 4'd0} < dyn_base_r)))) begin
                            m_clean_count_r <= rdata_i[95:64];
                            m_clean_idx_r   <= 32'd0;
                            m_clean_pyc_g_r <= {16'd0, rdata_i[15:0], 4'd0};
                            m_clean_builtins_r <= {16'd0, rdata_i[31:16], 4'd0};
                            clean_busy_addr_r <= rdata_i[63:32];
                            m_want_r <= 1'b1;
                            m_we_r   <= 1'b0;
                            m_addr_r <= rdata_i[63:32];
                            m_st_r   <= M_CLEAN_BUSY_W;
                        end else begin
                            phase_r <= P_PRELOAD;
                            m_clr_r <= 32'd0;
                            m_st_r  <= M_PRE;
                        end
                    end
                end
                M_CLEAN_BUSY_W: begin
                    if (m_ack) begin
                        // Mutant 39 clears compiler scratch even while busy.
                        if ((rdata_i != 128'd0) && (mut_r != 8'd39)) begin
                            phase_r <= P_PRELOAD;
                            m_clr_r <= 32'd0;
                            m_st_r  <= M_PRE;
                        end else if (clean_skip_i || (mut_r == 8'd44)) begin
                            // Slots still hold the INT 0 the last loop wrote.
                            m_clean_idle_r <= 1'b1;
                            phase_r <= P_PRELOAD;
                            m_clr_r <= 32'd0;
                            m_st_r  <= M_PRE;
                        end else begin
                            m_clean_idle_r <= 1'b1;
                            m_want_r <= 1'b1;
                            m_we_r   <= 1'b0;
                            m_addr_r <= PYCORE_GC_COMPILER_CLEANUP + 32'd16;
                            m_st_r   <= M_CLEAN_ADDR_W;
                        end
                    end
                end
                M_CLEAN_ADDR_W: begin
                    if (m_ack) begin
                        m_clean_word_r <= rdata_i;
                        unique case (m_clean_idx_r[1:0])
                            2'd0: m_clean_addr_r <= rdata_i[31:0];
                            2'd1: m_clean_addr_r <= rdata_i[63:32];
                            2'd2: m_clean_addr_r <= rdata_i[95:64];
                            default: m_clean_addr_r <= rdata_i[127:96];
                        endcase
                        m_want_r <= 1'b1;
                        m_we_r   <= 1'b1;
                        unique case (m_clean_idx_r[1:0])
                            2'd0: m_addr_r <= rdata_i[31:0];
                            2'd1: m_addr_r <= rdata_i[63:32];
                            2'd2: m_addr_r <= rdata_i[95:64];
                            default: m_addr_r <= rdata_i[127:96];
                        endcase
                        m_wdata_r <= 128'd0;
                        m_st_r <= M_CLEAN_VAL_W;
                    end
                end
                M_CLEAN_VAL_W: begin
                    if (m_ack) begin
                        m_want_r <= 1'b1;
                        m_we_r   <= 1'b1;
                        m_addr_r <= m_clean_addr_r + 32'd16;
                        m_wdata_r <= {124'd0, PY_TAG_INT};
                        m_st_r <= M_CLEAN_TAG_W;
                    end
                end
                M_CLEAN_TAG_W: begin
                    if (m_ack) begin
                        if (m_clean_idx_r + 32'd1 >= m_clean_count_r) begin
                            clean_done_r <= 1'b1;
                            phase_r <= P_PRELOAD;
                            m_clr_r <= 32'd0;
                            m_st_r  <= M_PRE;
                        end else if (m_clean_idx_r[1:0] == 2'd3) begin
                            m_clean_idx_r <= m_clean_idx_r + 32'd1;
                            m_want_r <= 1'b1;
                            m_we_r   <= 1'b0;
                            m_addr_r <= PYCORE_GC_COMPILER_CLEANUP + 32'd16 +
                                        (((m_clean_idx_r + 32'd1) >> 2) << 4);
                            m_st_r <= M_CLEAN_ADDR_W;
                        end else begin
                            m_clean_idx_r <= m_clean_idx_r + 32'd1;
                            unique case (m_clean_idx_r[1:0] + 2'd1)
                                2'd1: m_clean_addr_r <= m_clean_word_r[63:32];
                                2'd2: m_clean_addr_r <= m_clean_word_r[95:64];
                                default: m_clean_addr_r <= m_clean_word_r[127:96];
                            endcase
                            m_want_r <= 1'b1;
                            m_we_r   <= 1'b1;
                            unique case (m_clean_idx_r[1:0] + 2'd1)
                                2'd1: m_addr_r <= m_clean_word_r[63:32];
                                2'd2: m_addr_r <= m_clean_word_r[95:64];
                                default: m_addr_r <= m_clean_word_r[127:96];
                            endcase
                            m_wdata_r <= 128'd0;
                            m_st_r <= M_CLEAN_VAL_W;
                        end
                    end
                end

                // Static prune map -> bitmap, one word per static bitmap word.
                // Bits at or above dyn_base are masked off: a dynamic object
                // must never look pre-marked.
                M_PRE: begin
                    if ((m_clr_r < ((dyn_base_r + 32'd2047) >> 11)) && shadow_ok_r &&
                        (m_clr_r < 32'(SHADOW_WORDS))) begin
                        bm_q[m_clr_r[BM_AW-1:0]] <= shadow_q[m_clr_r[7:0]];
                        m_clr_r <= m_clr_r + 32'd1;
                    end else if ((m_clr_r < ((dyn_base_r + 32'd2047) >> 11)) &&
                                 (m_clr_r >= (PYCORE_GC_STATIC_MAP_BYTES >> 4))) begin
                        // Past the map region (static image above 1 MB):
                        // nothing is premarked, those objects are traced.
                        // Reading on would return run-table headers.
                        bm_q[m_clr_r[BM_AW-1:0]] <= '0;
                        m_clr_r <= m_clr_r + 32'd1;
                    end else if (m_clr_r < ((dyn_base_r + 32'd2047) >> 11)) begin
                        m_want_r <= 1'b1;
                        m_we_r   <= 1'b0;
                        m_addr_r <= PYCORE_GC_STATIC_MAP + (m_clr_r << 4);
                        m_st_r   <= M_PRE_W;
                    end else begin
                        shadow_ok_r <= 1'b1;
                        // The cleared _PYC_G can no longer lead to dynamic
                        // compiler arenas.  Premark just its header after the
                        // static-map preload, so the normal root walk skips
                        // its large table.  Busy collections leave it clear
                        // and trace every active scratch reference.
                        if (m_clean_idle_r)
                            bm_q[m_clean_pyc_g_r[BM_AW+10:11]][m_clean_pyc_g_r[10:4]] <= 1'b1;
                        // Builtins header too, when the image listed every
                        // kept builtins value at PYCORE_GC_EXTRA_ROOTS
                        // (field 0: it did not; trace the whole table).
                        if (m_clean_idle_r && (m_clean_builtins_r != 32'd0))
                            bm_q[m_clean_builtins_r[BM_AW+10:11]][m_clean_builtins_r[10:4]] <= 1'b1;
                        phase_r <= P_ROOTS_REG;
                        m_st_r  <= M_IDLE;
                    end
                end
                M_PRE_W: begin
                    if (m_ack) begin
                        logic [127:0] pw;
                        pw = (m_clr_r == (dyn_base_r >> 11))
                           ? (rdata_i & ((128'd1 << dyn_base_r[10:4]) - 128'd1))
                           : rdata_i;
                        bm_q[m_clr_r[BM_AW-1:0]] <= pw;
                        if (m_clr_r < 32'(SHADOW_WORDS))
                            shadow_q[m_clr_r[7:0]] <= pw;
                        m_clr_r <= m_clr_r + 32'd1;
                        m_st_r  <= M_PRE;
                    end
                end

                // Root stash: value slot then tag slot, then decode.
                M_STASH_V: begin
                    stash_cyc_r <= stash_cyc_r + 32'd1;
                    m_want_r  <= 1'b1;
                    m_we_r    <= 1'b1;
                    m_addr_r  <= PYCORE_GC_ROOT_STASH + 32'd16 + (stash_cnt_r << 5);
                    m_wdata_r <= m_ent_r[127:0];
                    m_st_r    <= M_STASH_VW;
                end
                M_STASH_VW: begin
                    stash_cyc_r <= stash_cyc_r + 32'd1;
                    if (m_ack) m_st_r <= M_STASH_T;
                end
                M_STASH_T: begin
                    stash_cyc_r <= stash_cyc_r + 32'd1;
                    m_want_r  <= 1'b1;
                    m_we_r    <= 1'b1;
                    m_addr_r  <= PYCORE_GC_ROOT_STASH + 32'd32 + (stash_cnt_r << 5);
                    m_wdata_r <= {124'd0, m_ent_r[131:128]};
                    m_st_r    <= M_STASH_TW;
                end
                M_STASH_TW: begin
                    stash_cyc_r <= stash_cyc_r + 32'd1;
                    if (m_ack) begin
                        stash_cnt_r <= stash_cnt_r + 32'd1;
                        m_st_r <= M_DEC;
                    end
                end

                M_DEC: begin
                    if (d_wild) wild_r <= wild_r + 32'd1;
                    if (d_reserved) reserved_r <= reserved_r + 32'd1;
                    if (d_badkind) bad_kind_r <= bad_kind_r + 32'd1;
`ifndef SYNTHESIS
                    if ($test$plusargs("GC_TRACE_DEC") &&
                        ((d_wild || d_reserved || d_badkind) ||
                         (d_act != 2'd0 && d_len > 32'd4096)))
                        $display("[GC-DEC] wild=%0d reserved=%0d badkind=%0d tag=%0h raw=%0d kind=%0d addr=%h len=%0d val=%h",
                                 d_wild, d_reserved, d_badkind, d_tag, d_raw, d_kind, d_addr, d_len, d_val);
`endif
                    m_g_r     <= d_g;
                    m_g_end_r <= d_ge;
                    m_push_r  <= (d_act == 2'd3);
                    m_pent_r  <= {d_kind, d_size, d_addr};
                    if (d_cont) begin
                        // Rest of a wide range: push as is, or record it.
                        m_pent_r <= d_val[66:0];
                        m_st_r   <= stk_full ? M_RESC_WR : M_PUSH;
                    end else if (d_act == 2'd0) begin
                        m_st_r <= M_IDLE;
                    end else if ((d_act != 2'd1) && d_marked) begin
                        m_st_r <= M_IDLE;
                    end else if ((d_act == 2'd3) && stk_full && m_have_ent_r) begin
                        // No room: leave the child unmarked and rescan the
                        // tracer's range later (once per range). Root items
                        // have no range; they are marked and recorded
                        // themselves (M_SPILL).
                        if (!m_resc_done_r) begin
                            m_resc_done_r <= 1'b1;
                            m_pent_r      <= t_re_r;
                            m_st_r        <= M_RESC_WR;
                        end else begin
                            m_st_r <= M_IDLE;
                        end
                    end else begin
                        bm_q[d_ww[BM_AW-1:0]] <= d_bword | d_mask;
                        if (d_one_word) begin
                            if (d_act == 2'd3) begin
                                if (cnt_r < (OC_AW+1)'(onchip_limit_r)) begin
                                    ring[OC_AW'(bot_r + OC_AW'(cnt_r))] <=
                                        {d_kind, d_size, d_addr};
                                    cnt_r  <= cnt_r + 1'b1;
                                    m_st_r <= M_IDLE;
                                end else begin
                                    m_batch_r <= 6'd0;
                                    m_st_r    <= M_SPILL;
                                end
                            end else begin
                                m_st_r <= M_IDLE;
                            end
                        end else begin
                            m_g_r  <= (d_ww + 32'd1) << 7;
                            m_st_r <= M_SET;
                        end
                    end
                end

                // Test the first granule; stop if the object is marked.
                M_TEST: begin
                    if (m_word[m_b_lo]) m_st_r <= M_IDLE;
                    else                m_st_r <= M_SET;
                end

                // Set every granule of [m_g, m_g_end], one bitmap word/cycle.
                M_SET: begin
                    bm_q[m_w[BM_AW-1:0]] <= m_word | m_mask;
                    if (m_w == m_w_end) begin
                        m_st_r <= m_push_r ? M_PUSH : M_IDLE;
                    end else begin
                        m_g_r <= (m_w + 32'd1) << 7;
                    end
                end

                M_PUSH: begin
                    if (cnt_r < (OC_AW+1)'(onchip_limit_r)) begin
                        ring[OC_AW'(bot_r + OC_AW'(cnt_r))] <= m_pent_r;
                        cnt_r  <= cnt_r + 1'b1;
                        m_st_r <= M_IDLE;
                    end else begin
                        m_batch_r <= 6'd0;
                        m_st_r    <= M_SPILL;
                    end
                end

                // Spill the oldest SPILL_BATCH on-chip entries.
                M_SPILL: begin
                    if ((m_batch_r == 6'(SPILL_BATCH)) || (cnt_r == '0) ||
                        ((onchip_limit_r < 9'd4) && (m_batch_r != 6'd0))) begin
                        m_st_r <= M_PUSH;
                    end else if (mem_cnt_r >= stack_limit_r) begin
                        // Memory part full. After a partial batch the ring
                        // has room; otherwise the stack is full (a root
                        // item: already marked, so record the entry itself).
                        m_st_r <= (m_batch_r != 6'd0) ? M_PUSH : M_RESC_WR;
                    end else begin
                        m_want_r  <= 1'b1;
                        m_we_r    <= 1'b1;
                        m_addr_r  <= PYCORE_GC_MARK_STACK + (mem_cnt_r << 4);
                        m_wdata_r <= {ring[bot_r][66:64], 29'd0, 32'd0,
                                      ring[bot_r][63:32], ring[bot_r][31:0]};
                        m_st_r    <= M_SPILL_W;
                    end
                end
                M_SPILL_W: begin
                    if (m_ack) begin
                        spill_xacts_r <= spill_xacts_r + 32'd1;
                        bot_r     <= bot_r + OC_AW'(1);
                        cnt_r     <= cnt_r - 1'b1;
                        mem_cnt_r <= mem_cnt_r + 32'd1;
                        m_batch_r <= m_batch_r + 6'd1;
                        m_st_r    <= M_SPILL;
                    end
                end

                // Refill up to SPILL_BATCH entries into the empty ring.
                M_REFILL: begin
                    if ((m_batch_r == 6'(SPILL_BATCH)) || (mem_cnt_r == 32'd0) ||
                        (cnt_r >= (OC_AW+1)'(onchip_limit_r))) begin
                        m_st_r <= M_IDLE;
                    end else begin
                        m_want_r <= 1'b1;
                        m_we_r   <= 1'b0;
                        m_addr_r <= PYCORE_GC_MARK_STACK + ((mem_cnt_r - 32'd1) << 4);
                        m_st_r   <= M_REFILL_W;
                    end
                end
                M_REFILL_W: begin
                    if (m_ack) begin
                        spill_xacts_r <= spill_xacts_r + 32'd1;
                        mem_cnt_r <= mem_cnt_r - 32'd1;
                        m_batch_r <= m_batch_r + 6'd1;
                        if (!((mut_r == 8'd37) && (m_batch_r == 6'd0))) begin
                            ring[OC_AW'(bot_r - OC_AW'(1))] <=
                                {rdata_i[127:125], rdata_i[63:32], rdata_i[31:0]};
                            bot_r <= bot_r - OC_AW'(1);
                            cnt_r <= cnt_r + 1'b1;
                        end
                        m_st_r <= M_REFILL;
                    end
                end

                // Record m_pent_r in the rescan list; give up when it is full.
                M_RESC_WR: begin
                    if (resc_cnt_r >= rescan_limit_r) begin
                        overflow_r <= 1'b1;
                        m_st_r     <= M_DONE;
                        phase_r    <= P_FINISH;
                    end else begin
                        m_want_r  <= 1'b1;
                        m_we_r    <= 1'b1;
                        m_addr_r  <= PYCORE_GC_RESCAN + (resc_cnt_r << 4);
                        m_wdata_r <= {m_pent_r[66:64], 29'd0, 32'd0,
                                      m_pent_r[63:32], m_pent_r[31:0]};
                        m_st_r    <= M_RESC_WR_W;
                    end
                end
                M_RESC_WR_W: begin
                    if (m_ack) begin
                        spill_xacts_r <= spill_xacts_r + 32'd1;
                        resc_cnt_r    <= resc_cnt_r + 32'd1;
                        rescans_r     <= rescans_r + 32'd1;
                        m_st_r        <= M_IDLE;
                    end
                end
                // Stack empty: move the newest recorded range back onto it.
                M_RESC_RD: begin
                    m_want_r <= 1'b1;
                    m_we_r   <= 1'b0;
                    m_addr_r <= PYCORE_GC_RESCAN + ((resc_cnt_r - 32'd1) << 4);
                    m_st_r   <= M_RESC_RD_W;
                end
                M_RESC_RD_W: begin
                    if (m_ack) begin
                        spill_xacts_r <= spill_xacts_r + 32'd1;
                        resc_cnt_r    <= resc_cnt_r - 32'd1;
                        ring[bot_r]   <= {rdata_i[127:125], rdata_i[63:32], rdata_i[31:0]};
                        cnt_r         <= cnt_r + 1'b1;
                        m_st_r        <= M_IDLE;
                    end
                end

                // ---- sweep ----
                // Kept current run: set its bits so the scan splits runs
                // around it (one bitmap word per cycle), and count it free.
                M_SW_KEEP: begin
                    logic [31:0]  lo_g, hi_g, w0g;
                    logic [128:0] hi_m, lo_m;
                    lo_g = keep_lo_r >> 4;
                    hi_g = keep_hi_r >> 4;
                    w0g  = keep_w_r << 7;
                    hi_m = (hi_g >= w0g + 32'd128) ? {1'b0, {128{1'b1}}}
                         : ((129'd1 << (hi_g - w0g)) - 129'd1);
                    lo_m = (lo_g <= w0g) ? 129'd0
                         : ((129'd1 << (lo_g - w0g)) - 129'd1);
                    // Mutant 42 also lists the kept run (double booking).
                    if (mut_r != 8'd42)
                        bm_q[keep_w_r[BM_AW-1:0]] <= bm_q[keep_w_r[BM_AW-1:0]] | (hi_m[127:0] & ~lo_m[127:0]);
                    if (keep_w_r >= ((hi_g - 32'd1) >> 7)) begin
                        free_bytes_r <= free_bytes_r + (keep_hi_r - keep_lo_r);
                        if ((keep_hi_r - keep_lo_r) > largest_size_r) begin
                            largest_size_r <= keep_hi_r - keep_lo_r;
                            largest_base_r <= keep_lo_r;
                        end
                        m_st_r <= M_SW_PRE;
                    end else begin
                        keep_w_r <= keep_w_r + 32'd1;
                    end
                end
                // Clear the bitmap words wholly below the dynamic heap.
                M_SW_PRE: begin
                    if (m_clr_r < (sw_g_r >> 7)) begin
                        if (mut_r != 8'd25) bm_q[m_clr_r[BM_AW-1:0]] <= '0;
                        m_clr_r <= m_clr_r + 32'd1;
                    end else begin
                        m_st_r <= M_SW_SCAN;
                    end
                end

                // One run boundary (or one whole word) per cycle.
                M_SW_SCAN: begin
                    logic        emit;
                    logic [31:0] run_end;
                    logic [31:0] slot;
                    logic        tbl_full;
                    logic        last_word;
                    emit = 1'b0;
                    run_end = '0;
                    tbl_full = (sw_tbl_r + 32'd16 >
                                PYCORE_GC_RUN_TABLE + PYCORE_GC_RUN_TABLE_BYTES);
                    slot = tbl_full ? (sw_run_start_r << 4) : sw_tbl_r;
                    last_word = (sw_w == ((sw_g_end_r - 32'd1) >> 7));
                    if (sw_g_r >= sw_g_end_r) begin
                        m_st_r <= M_SW_LAST;
                    end else if (sw_free_r) begin
                        if (sw_found) begin
                            run_end = (sw_w << 7) + {25'd0, sw_q};
                            if (mut_r == 8'd24) run_end = run_end + 32'd1;
                            emit = 1'b1;
                        end else if (last_word) begin
                            run_end = sw_g_end_r;
                            emit = 1'b1;
                        end else begin
                            if (mut_r != 8'd25) bm_q[sw_w[BM_AW-1:0]] <= '0;
                            sw_g_r <= (sw_w + 32'd1) << 7;
                        end
                        if (emit) begin
                            // Runs smaller than the 64 B alignment slack cannot
                            // satisfy ensure_run; listing them is 50+ cycles
                            // of header traffic per pad (G13 P4/P8).
                            if (((run_end - sw_run_start_r) << 4) < 32'd64) begin
                                free_bytes_r <= free_bytes_r
                                    + ((run_end - sw_run_start_r) << 4);
                                if (((run_end - sw_run_start_r) << 4) > largest_size_r) begin
                                    largest_size_r <= (run_end - sw_run_start_r) << 4;
                                    largest_base_r <= sw_run_start_r << 4;
                                end
                                sw_free_r <= 1'b0;
                                sw_g_r    <= (run_end >= sw_g_end_r)
                                           ? sw_g_end_r : run_end;
                            end else if ((poison_en_r || (run_onchip_n_r == 11'(RUN_ONCHIP)))
                                         && (swq_n_r == 3'd4)) begin
                                // Poison / overflow-table write queue full.
                            end else if (run_onchip_n_r != 11'(RUN_ONCHIP)) begin
                                if (run_onchip_n_r == 11'd0)
                                    run_head_r <= PYCORE_GC_RUN_TABLE;
                                run_base_q[run_onchip_n_r[9:0]] <= sw_run_start_r << 4;
                                run_size_q[run_onchip_n_r[9:0]] <=
                                    (run_end - sw_run_start_r) << 4;
                                if (poison_en_r) begin
                                    sw_enq = 1'b1;
                                    swq_base_r[swq_n_r[1:0]] <= sw_run_start_r << 4;
                                    swq_size_r[swq_n_r[1:0]] <=
                                        (run_end - sw_run_start_r) << 4;
                                    swq_next_r[swq_n_r[1:0]] <= 32'd0;
                                    swq_slot_r[swq_n_r[1:0]] <= 32'd0;
                                    swq_hdr_r[swq_n_r[1:0]]  <= 1'b0;
                                    swq_n_r <= swq_n_r + 3'd1;
                                end
                                run_onchip_n_r <= run_onchip_n_r + 11'd1;
                                if ((sw_run_start_r << 4) < rover_addr_r)
                                    run_rover_r <= run_onchip_n_r + 11'd1;
                                free_bytes_r   <= free_bytes_r
                                    + ((run_end - sw_run_start_r) << 4);
                                runs_r         <= runs_r + 32'd1;
                                if (((run_end - sw_run_start_r) << 4) > largest_size_r) begin
                                    largest_size_r <= (run_end - sw_run_start_r) << 4;
                                    largest_base_r <= sw_run_start_r << 4;
                                end
                                free_range_valid_o <= 1'b1;
                                free_range_base_o  <= sw_run_start_r << 4;
                                free_range_len_o   <= (run_end - sw_run_start_r) << 4;
                                sw_free_r <= 1'b0;
                                sw_g_r    <= (run_end >= sw_g_end_r) ? sw_g_end_r : run_end;
                            end else begin
                                // Overflow list. Once the sequential table is
                                // full the header goes in place, in the run's
                                // first granule (the allocator reads either
                                // form). Aborting here instead left the rest
                                // of the bitmap marked and raised MemoryError
                                // with most of the heap free.
                                if (sw_pend_r) begin
                                    sw_enq = 1'b1;
                                    swq_base_r[swq_n_r[1:0]] <= sw_pend_base_r;
                                    swq_size_r[swq_n_r[1:0]] <= sw_pend_size_r;
                                    swq_next_r[swq_n_r[1:0]] <= slot;
                                    swq_slot_r[swq_n_r[1:0]] <= sw_pend_slot_r;
                                    swq_hdr_r[swq_n_r[1:0]]  <= 1'b1;
                                    swq_n_r <= swq_n_r + 3'd1;
                                end else if (run_head_r == 32'd0) begin
                                    run_head_r <= slot;
                                end
                                if (run_overflow_head_r == 32'd0)
                                    run_overflow_head_r <= slot;
                                sw_pend_r      <= 1'b1;
                                sw_pend_base_r <= sw_run_start_r << 4;
                                sw_pend_size_r <= (run_end - sw_run_start_r) << 4;
                                sw_pend_slot_r <= slot;
                                if (!tbl_full) sw_tbl_r <= sw_tbl_r + 32'd16;
                                free_bytes_r   <= free_bytes_r + ((run_end - sw_run_start_r) << 4);
                                runs_r         <= runs_r + 32'd1;
                                if (((run_end - sw_run_start_r) << 4) > largest_size_r) begin
                                    largest_size_r <= (run_end - sw_run_start_r) << 4;
                                    largest_base_r <= sw_run_start_r << 4;
                                end
                                free_range_valid_o <= 1'b1;
                                free_range_base_o  <= sw_run_start_r << 4;
                                free_range_len_o   <= (run_end - sw_run_start_r) << 4;
                                sw_free_r <= 1'b0;
                                sw_g_r    <= (run_end >= sw_g_end_r) ? sw_g_end_r : run_end;
                            end
                        end
                    end else begin
                        if (sw_found) begin
                            sw_run_start_r <= (sw_w << 7) + {25'd0, sw_q};
                            sw_free_r <= 1'b1;
                            sw_g_r    <= (sw_w << 7) + {25'd0, sw_q};
                        end else if (last_word) begin
                            sw_g_r <= sw_g_end_r;
                        end else begin
                            if (mut_r != 8'd25) bm_q[sw_w[BM_AW-1:0]] <= '0;
                            sw_g_r <= (sw_w + 32'd1) << 7;
                        end
                    end
                end

                // Clear the last word, then write the final pending header.
                M_SW_LAST: begin
                    if (mut_r != 8'd25) bm_q[BM_AW'((sw_g_end_r - 32'd1) >> 7)] <= '0;
                    if (sw_pend_r && (swq_n_r != 3'd4)) begin
                        sw_enq = 1'b1;
                        swq_base_r[swq_n_r[1:0]] <= sw_pend_base_r;
                        swq_size_r[swq_n_r[1:0]] <= sw_pend_size_r;
                        swq_next_r[swq_n_r[1:0]] <= 32'd0;
                        swq_slot_r[swq_n_r[1:0]] <= sw_pend_slot_r;
                        swq_hdr_r[swq_n_r[1:0]]  <= 1'b1;
                        swq_n_r   <= swq_n_r + 3'd1;
                        sw_pend_r <= 1'b0;
                    end else if (!sw_pend_r && !sw_wr_busy_r && (swq_n_r == 3'd0)) begin
                        m_st_r <= M_FIN;
                    end
                end

                // M_FIN: stash count word (sim), then done.
                M_FIN: begin
                    if (stash_en_r) begin
                        m_want_r  <= 1'b1;
                        m_we_r    <= 1'b1;
                        m_addr_r  <= PYCORE_GC_ROOT_STASH;
                        m_wdata_r <= {96'd0, stash_cnt_r};
                        m_st_r    <= M_FIN_W;
                    end else begin
                        m_st_r <= M_DONE;
                    end
                end
                M_FIN_W: begin
                    if (m_ack) m_st_r <= M_DONE;
                end

                M_DONE: begin
                    if (!out_r && !m_want_r && !t_want_r) begin
                        phase_r <= P_IDLE;
                        t_st_r  <= T_IDLE;
                        m_st_r  <= M_IDLE;
                        done_r  <= 1'b1;
                    end
                end

                default: m_st_r <= M_IDLE;
            endcase

            // ---- sweep header / poison writer (runs beside M_SW_SCAN) ----
            if (sw_wr_busy_r && ((m_st_r == M_SW_SCAN) || (m_st_r == M_SW_LAST))) begin
                if (!m_want_r && !(out_r && out_owner_r)) begin
                    if ((sw_wr_off_r != 32'hFFFF_FFFF) && (sw_wr_off_r < sw_poison_lim)) begin
                        // A whole 64 B line inside the poison span goes as
                        // one line write of four poison words.
                        logic pl;
                        pl = line_wr_ok_i &&
                             ((sw_wr_base_r[5:0] + sw_wr_off_r[5:0]) == 6'd0) &&
                             (sw_wr_off_r + 32'd64 <= sw_poison_lim);
                        m_want_r  <= 1'b1;
                        m_we_r    <= 1'b1;
                        m_line_r  <= pl;
                        m_addr_r  <= sw_wr_base_r + sw_wr_off_r;
                        m_wdata_r <= PYCORE_GC_POISON_WORD;
                        sw_wr_off_r <= sw_wr_off_r + (pl ? 32'd64 : 32'd16);
                        if (sw_wr_base_r + sw_wr_off_r + (pl ? 32'd64 : 32'd16) > dirty_hi_r)
                            dirty_hi_r <= sw_wr_base_r + sw_wr_off_r + (pl ? 32'd64 : 32'd16);
                    end else if ((sw_wr_off_r != 32'hFFFF_FFFF) && sw_wr_hdr_r) begin
                        m_want_r  <= 1'b1;
                        m_we_r    <= 1'b1;
                        m_addr_r  <= sw_wr_slot_r;
                        m_wdata_r <= {PYCORE_GC_FREE_MAGIC, sw_wr_size_r,
                                      sw_wr_next_r, sw_wr_base_r};
                        sw_wr_off_r <= 32'hFFFF_FFFF;
                        if (sw_wr_base_r + 32'd16 > dirty_hi_r)
                            dirty_hi_r <= sw_wr_base_r + 32'd16;
                    end else begin
                        sw_wr_busy_r <= 1'b0;
                    end
                end
            end else if (!sw_wr_busy_r && (swq_n_r != 3'd0) && !sw_enq &&
                         ((m_st_r == M_SW_SCAN) || (m_st_r == M_SW_LAST))) begin
                sw_wr_busy_r <= 1'b1;
                sw_wr_base_r <= swq_base_r[0];
                sw_wr_slot_r <= swq_slot_r[0];
                sw_wr_size_r <= swq_size_r[0];
                sw_wr_next_r <= swq_next_r[0];
                sw_wr_hdr_r  <= swq_hdr_r[0];
                sw_wr_off_r  <= poison_en_r ? 32'd16 : swq_size_r[0];
                swq_base_r[0] <= swq_base_r[1];
                swq_base_r[1] <= swq_base_r[2];
                swq_base_r[2] <= swq_base_r[3];
                swq_slot_r[0] <= swq_slot_r[1];
                swq_slot_r[1] <= swq_slot_r[2];
                swq_slot_r[2] <= swq_slot_r[3];
                swq_size_r[0] <= swq_size_r[1];
                swq_size_r[1] <= swq_size_r[2];
                swq_size_r[2] <= swq_size_r[3];
                swq_next_r[0] <= swq_next_r[1];
                swq_next_r[1] <= swq_next_r[2];
                swq_next_r[2] <= swq_next_r[3];
                swq_hdr_r[0]  <= swq_hdr_r[1];
                swq_hdr_r[1]  <= swq_hdr_r[2];
                swq_hdr_r[2]  <= swq_hdr_r[3];
                swq_n_r <= swq_n_r - 3'd1;
            end

            // ---- tracer pending buffer: drain one, then append this cycle's
            // pushes (room was checked when the producing read was issued).
            begin
                logic [QW-1:0] nb [0:2];
                logic [1:0] n;
                nb[0] = tp_mem[0]; nb[1] = tp_mem[1]; nb[2] = tp_mem[2];
                n = tp_cnt_r;
                if (tp_drain) begin
                    nb[0] = nb[1]; nb[1] = nb[2];
                    n = n - 2'd1;
                end
                if (p1) begin nb[n] = i1; n = n + 2'd1; end
                if (p2) begin nb[n] = i2; n = n + 2'd1; end
                if (p3) begin nb[n] = i3; n = n + 2'd1; end
                tp_mem[0] <= nb[0]; tp_mem[1] <= nb[1]; tp_mem[2] <= nb[2];
                tp_cnt_r <= n;
            end

            if (fault_r || overflow_r) begin
                // An aborted collection leaves marks in the bitmap (and the
                // sweep, if it had started, cleared only part of it). Clear
                // it all before the next collection: a stale mark makes the
                // marker skip a live object's children and free them.
                if (phase_r != P_IDLE) bitmap_clean_r <= 1'b0;
                if ((phase_r != P_IDLE) && (phase_r != P_FINISH) && (m_st_r != M_DONE)) begin
`ifndef SYNTHESIS
                    if ($test$plusargs("GC_TRACE_DEC"))
                        $display("[GC-DEC] abort overflow=%0d fault=%0d phase=%0d m_st=%0d",
                                 overflow_r, fault_r, phase_r, m_st_r);
`endif
                    phase_r <= P_FINISH;
                    m_st_r  <= M_DONE;
                    t_st_r  <= T_IDLE;
                end
            end
        end
    end

    // Queue input mux and pop.
    assign q_push = root_take || tp_drain;
    assign q_din  = root_take ? {1'b1, 1'b0, root_entry_i} : tp_mem[0];
    assign q_pop  = (m_st_r == M_IDLE) && (q_cnt_r != 3'd0);
    assign pop_req = (t_st_r == T_POP);

`ifndef SYNTHESIS
    // G6 invariants that belong to the engine.
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (req_o && out_r)
                $fatal(1, "[GC-INV] engine issued a request with one outstanding");
            if (req_o && we_o &&
                !((addr_o >= PYCORE_GC_META_BASE) && (addr_o < PYCORE_DMEM_BYTES)) &&
                !((phase_r == P_CLEANUP) && (addr_o >= PYCORE_HEAP_BASE) &&
                  (addr_o < dyn_base_r)) &&
                !((phase_r == P_SWEEP) && (addr_o >= dyn_base_r) && (addr_o < heap_limit_r)))
                $fatal(1, "[GC-INV] engine write outside metadata / freed runs: addr=%h", addr_o);
            if (done_r && (cnt_r != '0 || mem_cnt_r != 32'd0 || resc_cnt_r != 32'd0) && !overflow_r)
                $fatal(1, "[GC-INV] mark stack not empty at end of collection");
            if (q_push && (q_cnt_r == 3'd4) && !q_pop)
                $fatal(1, "[GC-INV] engine queue overflow");
        end
    end
`endif
endmodule
