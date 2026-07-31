// pycore_cont_defs.svh — CONT_* / CP_* encodings for S_CONTAINER.
// Included inside pycore_core. Widened to 6 bits in M0 for object-protocol headroom.
    // Container sub-operation codes (stored in container_op_r, 6-bit).
    localparam logic [5:0] CONT_BUILD_LIST = 6'd0;
    localparam logic [5:0] CONT_SUBSCR_LIST = 6'd1; // NB_SUBSCR on LIST
    localparam logic [5:0] CONT_STORE_LIST = 6'd2; // STORE_SUBSCR on LIST
    localparam logic [5:0] CONT_BUILD_MAP = 6'd3; // BUILD_MAP (dict construction)
    localparam logic [5:0] CONT_SUBSCR_DICT = 6'd4; // NB_SUBSCR on DICT
    localparam logic [5:0] CONT_STORE_DICT = 6'd5; // STORE_SUBSCR on DICT
    localparam logic [5:0] CONT_BUILD_TUPLE = 6'd6; // BUILD_TUPLE
    localparam logic [5:0] CONT_SUBSCR_TUPLE = 6'd7; // NB_SUBSCR on TUPLE
    localparam logic [5:0] CONT_LOAD_CONST = 6'd8; // LOAD_CONST co_consts[arg]
    localparam logic [5:0] CONT_LOAD_GLOBAL = 6'd9; // LOAD_GLOBAL / LOAD_NAME
    localparam logic [5:0] CONT_STORE_NAME = 6'd10;// STORE_NAME / STORE_GLOBAL
    localparam logic [5:0] CONT_LFB_PAIR = 6'd11;// LFB_LFB / LFLF combined load
    localparam logic [5:0] CONT_LIST_APPEND = 6'd12;// LIST_APPEND fast path (Phase A)
    localparam logic [5:0] CONT_LIST_EXTEND = 6'd13;// LIST_EXTEND empty no-op / always excore
    localparam logic [5:0] CONT_SWAP = 6'd14;// SWAP two-beat RF exchange
    localparam logic [5:0] CONT_SFLF = 6'd15;// STORE_FAST_LOAD_FAST
    localparam logic [5:0] CONT_SFSF = 6'd16;// STORE_FAST_STORE_FAST
    localparam logic [5:0] CONT_LFAC = 6'd17;// LOAD_FAST_AND_CLEAR
    localparam logic [5:0] CONT_DELETE_LIST = 6'd18;// DELETE_SUBSCR on LIST
    localparam logic [5:0] CONT_CONTAINS_LIST = 6'd19;// CONTAINS_OP on LIST
    localparam logic [5:0] CONT_CONTAINS_TUPLE = 6'd20;// CONTAINS_OP on TUPLE
    localparam logic [5:0] CONT_CONTAINS_DICT = 6'd21;// CONTAINS_OP on DICT
    localparam logic [5:0] CONT_DELETE_DICT = 6'd22;// DELETE_SUBSCR on DICT
    localparam logic [5:0] CONT_BUILD_SET = 6'd23;// BUILD_SET
    localparam logic [5:0] CONT_SET_ADD = 6'd24;// SET_ADD probe/insert
    localparam logic [5:0] CONT_CONTAINS_SET = 6'd25;// CONTAINS_OP on SET
    localparam logic [5:0] CONT_SET_UPDATE = 6'd26;// SET_UPDATE → always trap
    localparam logic [5:0] CONT_GET_ITER = 6'd27;// LIST/TUPLE/RANGE/STR -> internal PTR
    localparam logic [5:0] CONT_FOR_ITER = 6'd28;// advance internal iterator
    localparam logic [5:0] CONT_LOAD_ATTR = 6'd29;// LOAD_ATTR (MRO + method form)
    localparam logic [5:0] CONT_STORE_ATTR = 6'd30;// STORE_ATTR → instance __dict__
    localparam logic [5:0] CONT_DELETE_ATTR = 6'd31;// DELETE_ATTR → instance __dict__
    localparam logic [5:0] CONT_UNPACK_SEQ = 6'd32;// UNPACK_SEQUENCE LIST/TUPLE

    // Container phases (stored in container_phase_r, 6-bit).
    //
    //   Shared / LIST phases:
    //     CP_INIT (0): First active cycle — set up the first dmem/RF op.
    //     CP_HDR  (1): In-flight header read/write; wait for dmem ack.
    //     CP_VAL  (2): In-flight element value read/write; wait for ack.
    //     CP_TAG  (3): In-flight element tag  read/write; wait for ack.
    //     CP_DONE (4): Terminal marker; always_comb → S_FETCH. Empty always_ff.
    //
    //   Dict-specific phases:
    //     CP_DICT_HASH    (5): RF addr settled; read key into regs; issue probe.
    //     CP_DICT_PROBE   (6): Probe ktag read acked; check empty/match/collision.
    //     CP_DICT_CHK_VAL (7): Probe kval read acked; compare value.
    //     CP_DICT_WR_KVAL (8): kval write acked; issue ktag write.
    //     CP_DICT_WR_KTAG (9): ktag write acked; set rf_addr for value.
    //     CP_DICT_RD_VAL  (10): Set rf_addr; issue vval write next cycle.
    //     CP_DICT_WR_VVAL (11): vval write acked; issue vtag write.
    //     CP_DICT_WR_VTAG (12): vtag write acked; loop BUILD_MAP or done.
    //     CP_DICT_RD_VVAL (13): acked → save val; issue vtag read.
    //     CP_DICT_RD_VTAG (14): vtag read acked → assemble result; done.
    //     (15 reserved)
    localparam logic [5:0] CP_INIT = 6'd0;
    localparam logic [5:0] CP_HDR = 6'd1;
    localparam logic [5:0] CP_VAL = 6'd2;
    localparam logic [5:0] CP_TAG = 6'd3;
    localparam logic [5:0] CP_DONE = 6'd4;
    localparam logic [5:0] CP_DICT_HASH = 6'd5;
    localparam logic [5:0] CP_DICT_PROBE = 6'd6;
    localparam logic [5:0] CP_DICT_CHK_VAL = 6'd7;
    localparam logic [5:0] CP_DICT_WR_KVAL = 6'd8;
    localparam logic [5:0] CP_DICT_WR_KTAG = 6'd9;
    localparam logic [5:0] CP_DICT_RD_VAL = 6'd10;
    localparam logic [5:0] CP_DICT_WR_VVAL = 6'd11;
    localparam logic [5:0] CP_DICT_WR_VTAG = 6'd12;
    localparam logic [5:0] CP_DICT_RD_VVAL = 6'd13;
    localparam logic [5:0] CP_DICT_RD_VTAG = 6'd14;
    // LOAD_GLOBAL: after the primary value writeback completes we may need a
    // second pulse to push a NULL sentinel (self_or_null) at the new TOS.
    localparam logic [5:0] CP_LG_WB_NULL = 6'd15;
    // LFB_LFB two-beat local read: first RF settle → wb; second RF settle → wb.
    localparam logic [5:0] CP_LFB_FIRST = 6'd16;
    localparam logic [5:0] CP_LFB_SECOND = 6'd17;
    // LOAD_GLOBAL / STORE_NAME name-tuple read prelude.  Distinct from
    // CP_HDR/CP_VAL/CP_TAG so the always_ff case tables stay legible.
    localparam logic [5:0] CP_NAME_VAL = 6'd18;
    localparam logic [5:0] CP_NAME_TAG = 6'd19;
    // LIST v2 / DICT v3 shared phases:
    //   CP_LIST_BUF (20): list ob_item OR dict table_ptr at obj_addr+16 —
    //     WRITE while installing (CONT_BUILD_LIST / CONT_BUILD_MAP) or READ
    //     while resolving the buffer/table base before element/slot access
    //     (CONT_SUBSCR_LIST/DICT, CONT_STORE_LIST/DICT, CONT_LIST_APPEND,
    //     CONT_CONTAINS_DICT, CONT_DELETE_DICT, LOAD_GLOBAL, STORE_NAME).
    //   CP_LIST_WB (21): header write-back ack (CONT_LIST_APPEND: commits
    //     length+1 after the element itself has been written).
    //   CP_SRC_HDR (22): CONT_LIST_EXTEND — waiting on source-list header
    //     (distinct LIST) before empty vs always-excore decision.
    localparam logic [5:0] CP_LIST_BUF = 6'd20;
    localparam logic [5:0] CP_LIST_WB = 6'd21;
    localparam logic [5:0] CP_SRC_HDR = 6'd22;
    // Iterator RF commit is deliberately two-beat: update iterator state,
    // then push the yielded element through the single RF write port.
    localparam logic [5:0] CP_ITER_WB = 6'd23;
    localparam logic [5:0] CP_ITEM_WB = 6'd24;
    // Attribute protocol (LOAD/STORE/DELETE_ATTR):
    //   CP_ATTR_HEAD     : ob_head ack — INSTANCE vs TYPE vs trap
    //   CP_ATTR_IDICT    : instance/type field0 (__dict__/tp_dict) val+tag
    //   CP_ATTR_TYPE     : MRO step — guard depth, issue type ob_head read
    //   CP_ATTR_TDICT    : type ob_head ack → verify OBK_TYPE → field0
    //   CP_ATTR_WB       : writeback attr / func / bound-method handle
    //   CP_ATTR_WB_SELF  : method_flag follow-up (self or NULL)
    //   CP_ATTR_BOUND*   : allocate OBK_BOUND_METHOD (96B) field writes
    //   CP_ATTR_STATIC*  : unwrap OBK_BUILTIN id=0 (staticmethod) → CODE_OBJECT
    //                      Overlay: lfb_lo[2]=1 marks static (no self bind).
    localparam logic [5:0] CP_ATTR_HEAD = 6'd25;
    localparam logic [5:0] CP_ATTR_IDICT = 6'd26;
    localparam logic [5:0] CP_ATTR_TYPE = 6'd27;
    localparam logic [5:0] CP_ATTR_TDICT = 6'd28;
    localparam logic [5:0] CP_ATTR_WB = 6'd29;
    localparam logic [5:0] CP_ATTR_WB_SELF = 6'd30;
    localparam logic [5:0] CP_ATTR_BOUND0 = 6'd31;
    localparam logic [5:0] CP_ATTR_BOUND1 = 6'd32;
    localparam logic [5:0] CP_ATTR_BOUND2 = 6'd33;
    localparam logic [5:0] CP_ATTR_BOUND3 = 6'd34;
    localparam logic [5:0] CP_ATTR_STATIC0 = 6'd35;
    localparam logic [5:0] CP_ATTR_STATIC1 = 6'd36;
    localparam logic [5:0] CP_ATTR_STATIC2 = 6'd37;
    localparam logic [5:0] CP_ATTR_STATIC3 = 6'd38;
    localparam logic [5:0] CP_ATTR_STATIC4 = 6'd39;
    // Tuple-mode RANGE GET_ITER reads start/stop/step value/tag pairs.
    localparam logic [5:0] CP_RANGE_START_VAL = 6'd41;
    localparam logic [5:0] CP_RANGE_START_TAG = 6'd42;
    localparam logic [5:0] CP_RANGE_STOP_VAL = 6'd43;
    localparam logic [5:0] CP_RANGE_STOP_TAG = 6'd44;
    localparam logic [5:0] CP_RANGE_STEP_VAL = 6'd45;
    localparam logic [5:0] CP_RANGE_STEP_TAG = 6'd46;
    // DICT v3 metadata/order-sidecar phases. Values may be reused by other
    // container operations because each operation has its own case table.
    localparam logic [5:0] CP_DICT_META = 6'd47;
    localparam logic [5:0] CP_DICT_META_FINAL = 6'd48;
    localparam logic [5:0] CP_DICT_ORDER_VAL = 6'd49;
    localparam logic [5:0] CP_DICT_ORDER_TAG = 6'd50;
    localparam logic [5:0] CP_DICT_ORDER_SCAN_VAL = 6'd51;
    localparam logic [5:0] CP_DICT_ORDER_SCAN_TAG = 6'd52;
    localparam logic [5:0] CP_DICT_ORDER_SHIFT_VAL_RD = 6'd53;
    localparam logic [5:0] CP_DICT_ORDER_SHIFT_VAL_WR = 6'd54;
    localparam logic [5:0] CP_DICT_ORDER_SHIFT_TAG_RD = 6'd55;
    localparam logic [5:0] CP_DICT_ORDER_SHIFT_TAG_WR = 6'd56;
    localparam logic [5:0] CP_DICT_ORDER_FINAL = 6'd57;

