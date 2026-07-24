`include "pycore_defs.svh"

// PyCore CPU core: a multi-cycle, non-pipelined machine. Exactly one
// instruction is in flight at a time; a control FSM walks it through
// fetch -> decode -> execute -> memory -> writeback over several cycles and
// only then fetches the next instruction. Because nothing is pipelined there
// is no operand forwarding, no load-use hazard, and no branch flush: the
// register file is always coherent by the time the next instruction reads it.
//
// The core remains a memory master. There is no imem_rdata_i loopback into the
// datapath; instruction fetch and the MEM stage drive synchronous req/ack
// master ports with a one-cycle access latency.
//
// FSM states:
//   S_FETCH  : run pycore_fetch (which folds EXTENDED_ARG and skips CACHE
//              internally) until a real instruction is presented, then latch
//              {opcode, arg, pc}.
//   S_DECODE : drive the register-file read addresses and latch the operands.
//   S_EXEC   : run the execute fabric / branch unit; hold while a multi-cycle
//              execute unit stalls.
//   S_MEM    : run pycore_mem_stage; hold while a data-memory access is in
//              flight (PTR load/store) and capture the writeback entry.
//   S_WB     : write the register file, advance the operand-stack pointer, and
//              redirect fetch on a taken branch.
//   S_CALL   : interact with pycore_frame for a CALL instruction.  Issues
//              call_valid, drains any register-spill transactions through dmem
//              (one write per evicted slot), then waits for init_new_frame.
//   S_RETURN : interact with pycore_frame for RETURN_VALUE.  Issues
//              return_valid in one cycle and redirects fetch to the saved PC.
//   S_HALT   : terminal state_r entered on any trap; the machine freezes.
module pycore_core #(
    parameter int ADDR_WIDTH    = PYCORE_ADDR_WIDTH,
    parameter int IMEM_DATA_W   = PYCORE_IMEM_DATA_WIDTH,
    parameter int DMEM_DATA_W   = PYCORE_DMEM_DATA_WIDTH,
    // Deep call graphs (e.g. img_deep_callgraph) keep every live frame's
    // locals/args resident in the RF, so depth is limited by RF_DEPTH more
    // tightly than by the dmem frame-descriptor stack.  256 entries leaves
    // headroom above fib(10)-class recursion.
    parameter int RF_DEPTH      = 256,
    parameter int STACK_BASE    = 32,
    parameter int STACK_TOP_MAX = 255,
    parameter string STRING_HEX = "pycore/programs/string_mem.hex",
    // First free byte of the bump-pointer heap.  A preloaded static heap
    // image sets this above the static objects so runtime allocations do
    // not overwrite them.  Default matches an empty heap.
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE,
    // BOOT_EN = 1 : after reset, walk the PYCORE_BOOT_RECORD_ADDR pair to
    //               locate the module code object + globals dict, cache
    //               consts/names, and jump fetch to the module entry slot
    //               (S_BOOT).  This is the CPython image-boot flow.
    // BOOT_EN = 0 : skip S_BOOT and start fetching at PC 0 with empty
    //               globals/consts/names.  Retained for legacy hex
    //               fixtures (tb_container programs) that hand-assemble
    //               streams using only LOAD_SMALL_INT and stack ops.
    parameter bit BOOT_EN = 1'b1,
    // EXCORE_EN = 1 : a recoverable trap (pycore_trap_recoverable(code))
    //                 enters S_TRAP_MARSHAL / S_TRAP_WAIT instead of
    //                 halting -- see pycore_excore_system.sv (Phase C).
    // EXCORE_EN = 0 : default.  Every legacy unit tb instantiates
    //                 pycore_core (via pycore_system) without overriding
    //                 this, so trap behavior is byte-identical to Phase A.
    parameter bit EXCORE_EN = 1'b0,
    parameter int MAX_TRAP_ENTRIES = 3,
    parameter int MAX_RES_ENTRIES  = 2
) (
    input  logic                          clk_i,
    input  logic                          rst_n_i,
    // imem master
    output logic                          imem_req_o,
    output logic                          imem_we_o,
    output logic [ADDR_WIDTH-1:0]         imem_addr_o,
    output logic [IMEM_DATA_W-1:0]        imem_wdata_o,
    input  logic                          imem_ack_i,
    input  logic [IMEM_DATA_W-1:0]        imem_rdata_i,
    input  logic                          imem_fault_i,
    // dmem master
    output logic                          dmem_req_o,
    output logic                          dmem_we_o,
    output logic [ADDR_WIDTH-1:0]         dmem_addr_o,
    output logic [DMEM_DATA_W-1:0]        dmem_wdata_o,
    input  logic                          dmem_ack_i,
    input  logic [DMEM_DATA_W-1:0]        dmem_rdata_i,
    input  logic                          dmem_fault_i,
    // trap_req (pycore -> excore, via trap_mailbox.sv). Unused (tied off)
    // when EXCORE_EN=0.
    output logic                          trap_req_valid_o,
    input  logic                          trap_req_ready_i,
    output logic [3:0]                    trap_req_code_o,
    output logic [31:0]                   trap_req_pc_o,
    output logic [39:0]                   trap_req_instr_o,
    output logic [31:0]                   trap_req_heap_ptr_o,
    output logic [2:0]                    trap_req_entry_count_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] trap_req_entries_o [0:MAX_TRAP_ENTRIES-1],
    // trap_res (excore -> pycore, via trap_mailbox.sv).
    input  logic                          trap_res_valid_i,
    output logic                          trap_res_ready_o,
    input  logic [3:0]                    trap_res_code_i,
    input  logic [3:0]                    trap_res_fatal_code_i,
    input  logic [2:0]                    trap_res_pop_count_i,
    input  logic [1:0]                    trap_res_push_count_i,
    input  logic [31:0]                   trap_res_heap_ptr_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] trap_res_entries_i [0:MAX_RES_ENTRIES-1],
    // status
    output logic                          trap_out_o,
    output logic [3:0]                    trap_code_o,
    output logic [63:0]                   cycle_count_o,
    // debug writeback snoop (for verification; mirrors the RF write port)
    output logic                          dbg_wb_we_o,
    output logic [7:0]                    dbg_wb_addr_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry_o
);

    localparam int RF_AW = $clog2(RF_DEPTH);

    // FSM states (4-bit to accommodate S_CONTAINER and S_BOOT).
    localparam logic [3:0] S_FETCH     = 4'd0;
    localparam logic [3:0] S_DECODE    = 4'd1;
    localparam logic [3:0] S_EXEC      = 4'd2;
    localparam logic [3:0] S_MEM       = 4'd3;
    localparam logic [3:0] S_WB        = 4'd4;
    localparam logic [3:0] S_HALT      = 4'd5;
    localparam logic [3:0] S_CALL      = 4'd6;
    localparam logic [3:0] S_RETURN    = 4'd7;
    // S_CONTAINER: multi-cycle handler for BUILD_LIST, BUILD_MAP, BUILD_TUPLE,
    // NB_SUBSCR, STORE_SUBSCR, LOAD_CONST, LOAD_GLOBAL, LOAD_NAME,
    // STORE_NAME/STORE_GLOBAL, and LFB_LFB.  Entered from S_EXEC when
    // dec_is_container is asserted; exits to S_FETCH when done.
    localparam logic [3:0] S_CONTAINER = 4'd8;
    // S_BOOT: reset entry state when BOOT_EN=1.  Reads the boot record
    // (module code object + globals dict), latches globals_base_r /
    // cur_code_r / consts_base_r / names_base_r from the module code
    // object, then redirects fetch to the entry slot before dropping
    // into S_FETCH for normal execution.
    localparam logic [3:0] S_BOOT      = 4'd9;
    // S_TRAP_MARSHAL / S_TRAP_WAIT (Phase C, EXCORE_EN=1 only): entered
    // instead of the fatal-halt path when a recoverable trap
    // (pycore_trap_recoverable(code)) fires.  S_TRAP_MARSHAL asserts
    // trap_req_valid_o with the already-gathered operand entries (no dmem
    // or RF activity — pycore is "frozen" per the memory-ownership
    // protocol) until the mailbox handshake completes; S_TRAP_WAIT then
    // waits for trap_res_valid_i and applies the result (see the
    // always_ff case below).
    localparam logic [3:0] S_TRAP_MARSHAL = 4'd10;
    localparam logic [3:0] S_TRAP_WAIT    = 4'd11;

    // trap_res_code_i values (mirrors excore/docs/mmio_map.md RES_CODE).
    localparam logic [3:0] TRAP_RES_COMPLETED = 4'd0;
    localparam logic [3:0] TRAP_RES_RETRY     = 4'd1;
    localparam logic [3:0] TRAP_RES_FATAL     = 4'd2;

    // Container sub-operation codes (stored in container_op_r, 5-bit).
    localparam logic [4:0] CONT_BUILD_LIST   = 5'd0;
    localparam logic [4:0] CONT_SUBSCR_LIST  = 5'd1; // NB_SUBSCR on LIST
    localparam logic [4:0] CONT_STORE_LIST   = 5'd2; // STORE_SUBSCR on LIST
    localparam logic [4:0] CONT_BUILD_MAP    = 5'd3; // BUILD_MAP (dict construction)
    localparam logic [4:0] CONT_SUBSCR_DICT  = 5'd4; // NB_SUBSCR on DICT
    localparam logic [4:0] CONT_STORE_DICT   = 5'd5; // STORE_SUBSCR on DICT
    localparam logic [4:0] CONT_BUILD_TUPLE  = 5'd6; // BUILD_TUPLE
    localparam logic [4:0] CONT_SUBSCR_TUPLE = 5'd7; // NB_SUBSCR on TUPLE
    localparam logic [4:0] CONT_LOAD_CONST   = 5'd8; // LOAD_CONST co_consts[arg]
    localparam logic [4:0] CONT_LOAD_GLOBAL  = 5'd9; // LOAD_GLOBAL / LOAD_NAME
    localparam logic [4:0] CONT_STORE_NAME   = 5'd10;// STORE_NAME / STORE_GLOBAL
    localparam logic [4:0] CONT_LFB_PAIR     = 5'd11;// LFB_LFB / LFLF combined load
    localparam logic [4:0] CONT_LIST_APPEND  = 5'd12;// LIST_APPEND fast path (Phase A)
    localparam logic [4:0] CONT_LIST_EXTEND  = 5'd13;// LIST_EXTEND empty no-op / always excore
    localparam logic [4:0] CONT_SWAP         = 5'd14;// SWAP two-beat RF exchange
    localparam logic [4:0] CONT_SFLF         = 5'd15;// STORE_FAST_LOAD_FAST
    localparam logic [4:0] CONT_SFSF         = 5'd16;// STORE_FAST_STORE_FAST
    localparam logic [4:0] CONT_LFAC         = 5'd17;// LOAD_FAST_AND_CLEAR
    localparam logic [4:0] CONT_DELETE_LIST  = 5'd18;// DELETE_SUBSCR on LIST
    localparam logic [4:0] CONT_CONTAINS_LIST  = 5'd19;// CONTAINS_OP on LIST
    localparam logic [4:0] CONT_CONTAINS_TUPLE = 5'd20;// CONTAINS_OP on TUPLE
    localparam logic [4:0] CONT_CONTAINS_DICT  = 5'd21;// CONTAINS_OP on DICT
    localparam logic [4:0] CONT_DELETE_DICT  = 5'd22;// DELETE_SUBSCR on DICT
    localparam logic [4:0] CONT_BUILD_SET    = 5'd23;// BUILD_SET
    localparam logic [4:0] CONT_SET_ADD      = 5'd24;// SET_ADD probe/insert
    localparam logic [4:0] CONT_CONTAINS_SET = 5'd25;// CONTAINS_OP on SET
    localparam logic [4:0] CONT_SET_UPDATE   = 5'd26;// SET_UPDATE → always trap

    // Container phases (stored in container_phase_r, 4-bit).
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
    localparam logic [4:0] CP_INIT        = 5'd0;
    localparam logic [4:0] CP_HDR         = 5'd1;
    localparam logic [4:0] CP_VAL         = 5'd2;
    localparam logic [4:0] CP_TAG         = 5'd3;
    localparam logic [4:0] CP_DONE        = 5'd4;
    localparam logic [4:0] CP_DICT_HASH   = 5'd5;
    localparam logic [4:0] CP_DICT_PROBE  = 5'd6;
    localparam logic [4:0] CP_DICT_CHK_VAL= 5'd7;
    localparam logic [4:0] CP_DICT_WR_KVAL= 5'd8;
    localparam logic [4:0] CP_DICT_WR_KTAG= 5'd9;
    localparam logic [4:0] CP_DICT_RD_VAL = 5'd10;
    localparam logic [4:0] CP_DICT_WR_VVAL= 5'd11;
    localparam logic [4:0] CP_DICT_WR_VTAG= 5'd12;
    localparam logic [4:0] CP_DICT_RD_VVAL= 5'd13;
    localparam logic [4:0] CP_DICT_RD_VTAG= 5'd14;
    // LOAD_GLOBAL: after the primary value writeback completes we may need a
    // second pulse to push a NULL sentinel (self_or_null) at the new TOS.
    localparam logic [4:0] CP_LG_WB_NULL  = 5'd15;
    // LFB_LFB two-beat local read: first RF settle → wb; second RF settle → wb.
    localparam logic [4:0] CP_LFB_FIRST   = 5'd16;
    localparam logic [4:0] CP_LFB_SECOND  = 5'd17;
    // LOAD_GLOBAL / STORE_NAME name-tuple read prelude.  Distinct from
    // CP_HDR/CP_VAL/CP_TAG so the always_ff case tables stay legible.
    localparam logic [4:0] CP_NAME_VAL    = 5'd18;
    localparam logic [4:0] CP_NAME_TAG    = 5'd19;
    // LIST v2 / DICT v2 shared phases:
    //   CP_LIST_BUF (20): list ob_item OR dict table_ptr at obj_addr+16 —
    //     WRITE while installing (CONT_BUILD_LIST / CONT_BUILD_MAP) or READ
    //     while resolving the buffer/table base before element/slot access
    //     (CONT_SUBSCR_LIST/DICT, CONT_STORE_LIST/DICT, CONT_LIST_APPEND,
    //     CONT_CONTAINS_DICT, CONT_DELETE_DICT, LOAD_GLOBAL, STORE_NAME).
    //   CP_LIST_WB (21): header write-back ack (CONT_LIST_APPEND: commits
    //     length+1 after the element itself has been written).
    //   CP_SRC_HDR (22): CONT_LIST_EXTEND — waiting on source-list header
    //     (distinct LIST) before empty vs always-excore decision.
    //   CP_EXT_SRC_BUF / CP_EXT_DST_VAL / CP_EXT_DST_TAG (23–25): unused by
    //     current LIST_EXTEND (copy moved to excore); phase codes retained.
    localparam logic [4:0] CP_LIST_BUF    = 5'd20;
    localparam logic [4:0] CP_LIST_WB     = 5'd21;
    localparam logic [4:0] CP_SRC_HDR     = 5'd22;
    localparam logic [4:0] CP_EXT_SRC_BUF = 5'd23;
    localparam logic [4:0] CP_EXT_DST_VAL = 5'd24;
    localparam logic [4:0] CP_EXT_DST_TAG = 5'd25;

    logic [3:0] state_r;

    // Per-instruction registers.
    logic [7:0]                    cur_opcode_r;
    logic [31:0]                   cur_arg_r;
    logic [31:0]                   cur_pc_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs1_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs2_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_entry_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_addr_entry_r;
    logic                          branch_take_r;
    logic [31:0]                   branch_tgt_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] wb_entry_r;
    logic                          wb_we_r;
    logic [RF_AW-1:0]              tos_r;

    // Currently-executing code object (byte address into dmem; upper bits 0).
    // Latched by S_BOOT / S_CALL / S_RETURN; consumed by S_RETURN to reload
    // consts/names before the caller resumes fetching.  Also pushed into the
    // frame descriptor on CALL and restored on RETURN.
    logic [31:0]                   cur_code_r;
    // Cached tuple handle (VAL field) of co_consts / co_names for the running
    // code object.  {size[63:0], addr[63:0]} — bounds check uses size, element
    // reads use addr via pycore_tuple_val_addr / pycore_tuple_tag_addr.
    logic [127:0]                  consts_base_r;
    logic [127:0]                  names_base_r;
    // Globals dictionary base address (byte address of the DICT header).
    // Latched once by S_BOOT and read/written by LOAD_GLOBAL / LOAD_NAME /
    // STORE_NAME / STORE_GLOBAL.  Zero when BOOT_EN=0 — legacy container
    // tests that never touch a global will not read this register.
    logic [31:0]                   globals_base_r;

    // One-cycle RF write issued from S_RETURN to deposit the callee's return
    // value at tos_base on the caller's stack before resuming fetch.
    logic             return_wb_we_r;
    logic [RF_AW-1:0] return_wb_addr_r;

    // Fetch handshake bookkeeping.
    logic                          fetch_skip_r;
    logic                          redirect_pending_r;
    logic [31:0]                   redirect_tgt_r;

    // S_CALL / S_RETURN management (multi-phase FSM with code-object reads).
    logic                          call_sent_r;   // call_valid was pulsed
    logic                          frame_dmem_pending_r; // frame push or pop in flight
    logic [3:0]                    call_phase_r;
    logic [2:0]                    return_phase_r;
    // Boot phase counter — reset walker for S_BOOT.
    logic [3:0]                    boot_phase_r;
    // Scratchpad regs latched during S_CALL / S_RETURN for a pending
    // frame transition.  Preserved across the code-object reads so the
    // frame push finally uses the callee's freshly-read fields.
    logic [31:0]                   call_code_addr_r;   // callee code byte addr
    logic [63:0]                   call_entry_slot_r;  // entry slot index
    logic [127:0]                  call_consts_r;      // callee co_consts TUPLE
    logic [127:0]                  call_names_r;       // callee co_names TUPLE
    logic [15:0]                   call_argcount_r;    // callee metadata argcount
    logic [15:0]                   call_nlocals_r;     // callee metadata nlocals
    logic [RF_AW-1:0]              call_new_locals_r;  // tos - argc
    logic [RF_AW-1:0]              call_tos_base_r;    // tos - argc - 2
    // One-cycle pulse: raise PY_TRAP_CALL_FILTER for callable checks and
    // frame_fault so the trap block sees a proper CALL_FILTER code rather
    // than being multiplexed through ILLEGAL_OPCODE.
    logic                          call_filter_trap_r;

    // -----------------------------------------------------------------------
    // S_CONTAINER state — heap allocator and container operation registers.
    // -----------------------------------------------------------------------
    // Heap bump allocator.  Starts at PYCORE_HEAP_BASE and grows upward.
    // OOM is detected before each allocation; traps PY_TRAP_MEM_FAULT.
    logic [31:0]                   heap_ptr_r;

    // Which container operation is in flight (CONT_* constants above).
    logic [4:0]                    container_op_r;
    // Which phase within the current operation (CP_* constants above).
    logic [4:0]                    container_phase_r;
    // LOAD_GLOBAL push-null bit (oparg & 1 in CPython 3.14).  Sampled at
    // container init so the CP_LG_WB_NULL follow-up knows whether to push
    // the sentinel after the primary value writeback.
    logic                          container_push_null_r;
    // Combined LFB_LFB local indices captured at container init so the
    // container FSM does not have to slice cur_arg_r inside multiple phases.
    logic [3:0]                    container_lfb_hi_r;
    logic [3:0]                    container_lfb_lo_r;
    // Element / pair counter.
    logic [6:0]                    container_idx_r;
    // Total element/pair count.
    logic [6:0]                    container_count_r;
    // Base address of the newly allocated container in heap.
    logic [31:0]                   container_base_r;
    // Saved element/key tag.
    logic [3:0]                    container_tag_r;
    // Saved element/key value[127:0].
    logic [127:0]                  container_val_r;
    // RF address override: while state_r == S_CONTAINER, the regfile rs1 port
    // is presented with container_rf_addr_r instead of dec_rs1_sel so that the
    // container FSM can read arbitrary RF slots without an extra RF read port.
    logic [RF_AW-1:0]              container_rf_addr_r;
    // Latched dmem read data (header, key_val, tag reads return data here).
    logic [127:0]                  container_rd_data_r;
    // Dict-specific: power-of-two slot count; linear-probe index; RF addr of value.
    logic [31:0]                   container_slot_count_r;
    logic [31:0]                   container_probe_r;
    logic [RF_AW-1:0]              container_val_rf_addr_r;
    // Dict used-count (header[63:0]); tracked during BUILD_MAP / STORE_DICT.
    logic [63:0]                   container_used_r;
    // Number of probe slots examined in the current probe sequence.
    logic [31:0]                   container_probe_n_r;
    // 1 = current STORE_DICT / BUILD_MAP write is inserting into an empty slot
    // (must bump used); 0 = overwrite of an existing key.
    logic                          container_insert_new_r;
    // 1 = BUILD_MAP finishing: header used-count rewrite in flight before commit.
    logic                          container_finishing_r;
    // LIST v2 (split object/buffer): buffer base address, resolved from the
    // object's ob_item field (CONT_BUILD_LIST / CONT_SUBSCR_LIST /
    // CONT_STORE_LIST / CONT_LIST_APPEND all funnel element addressing
    // through this register once ob_item has been read or chosen).
    logic [31:0]                   container_buf_r;
    // CONT_LIST_APPEND: snapshot of the object header {capacity,length} at
    // the moment the fast-path decision is made, held across the ob_item
    // read and element writes (container_rd_data_r gets overwritten by
    // those later dmem acks, so the header must be preserved separately).
    logic [PYCORE_VAL_WIDTH-1:0]   container_list_hdr_r;
    // One-cycle pulse: CONT_LIST_APPEND raised PY_TRAP_LIST_GROW (list at
    // capacity). Phase A has no excore, so this is fatal like any other
    // trap; raised strictly before any RF/heap commit (CP_HDR, before the
    // ob_item read) so a future RETRY-based recovery stays valid.
    logic                          container_list_grow_trap_r;
    // CONT_LIST_EXTEND: source iterable buffer base (list ob_item or tuple
    // addr) and source length, held across the destination copy loop.
    logic [31:0]                   container_src_buf_r;
    logic [31:0]                   container_src_len_r;
    logic [31:0]                   container_dst_len_r;
    // One-cycle pulse: CONT_LIST_EXTEND non-empty source (always excore).
    logic                          container_list_extend_trap_r;
    // One-cycle pulse: CONT_DELETE_LIST needs an element shift (excore).
    logic                          container_list_delete_trap_r;
    // One-cycle pulses: dict/set grow (fatal when EXCORE_EN=0; otherwise
    // marshaled like LIST_GROW before any commit).
    logic                          container_dict_grow_trap_r;
    // Legacy stub (dict collisions resolved on pycore via rich_eq).
    logic                          container_dict_collision_trap_r;
    logic                          container_set_grow_trap_r;
    logic                          container_set_update_trap_r;
    // Occupied probe slot tag latched at CP_DICT_PROBE for rich_eq at CHK_VAL.
    logic [3:0]                    container_probe_tag_r;
    // STORE_DICT / STORE_NAME / SET_ADD: first tombstone index seen during
    // probe (insert target when the key/element is absent).
    logic                          container_tomb_valid_r;
    logic [31:0]                   container_tomb_idx_r;

    // -----------------------------------------------------------------------
    // S_TRAP_MARSHAL / S_TRAP_WAIT (Phase C) registers.
    // -----------------------------------------------------------------------
    // Set (alongside container_phase_r <= CP_DONE) by a container op that
    // detects a recoverable trap under EXCORE_EN=1, instead of raising the
    // fatal one-cycle pulse (e.g. container_list_grow_trap_r). Selects
    // S_TRAP_MARSHAL over S_FETCH as the CP_DONE exit target; cleared on
    // entry to S_TRAP_MARSHAL.
    logic                          trap_marshal_pending_r;
    logic [3:0]                    trap_marshal_code_r;
    logic [2:0]                    trap_marshal_entry_count_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_marshal_entries_r [0:2]; // MAX_TRAP_ENTRIES
    // S_TRAP_WAIT: sequences push_count_i RF writes (one per cycle) after
    // popping pop_count_i, before applying COMPLETED/RETRY/FATAL.
    logic [1:0]                    trap_wait_push_idx_r;
    // 1 once the result fields below have been latched from trap_res_*_i
    // (the first cycle trap_res_valid_i is seen); cleared once the
    // resume/retry/fatal decision has been applied.
    logic                          trap_res_seen_r;
    logic [3:0]                    trap_res_code_r2;
    logic [3:0]                    trap_res_fatal_r2;
    logic [1:0]                    trap_res_push_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_res_entries_r2 [0:1]; // MAX_RES_ENTRIES
    // One-cycle pulse: forward an excore-reported FATAL code into
    // pycore_trap as a normal halt.
    logic                          excore_fatal_trap_r;
    logic [3:0]                    excore_fatal_code_r;

    // S_CONTAINER dmem handshake (mirrors frame_dmem_pending_r for S_CALL).
    logic                          container_dmem_pending_r;
    logic [31:0]                   container_dmem_addr_r;
    logic                          container_dmem_we_r;
    logic [127:0]                  container_dmem_wdata_r;

    // One-cycle RF write pulse from S_CONTAINER (mirrors return_wb_*).
    logic                          container_wb_we_r;
    logic [RF_AW-1:0]              container_wb_addr_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] container_wb_data_r;

    // One-cycle trap pulses raised inside S_CONTAINER.
    // These are cleared every cycle by the default-clear block above; a non-zero
    // value persists for exactly one clock cycle.
    logic                          container_type_trap_r;
    logic                          container_mem_fault_r;

    // One-cycle pulse outputs to frame manager (registered).
    logic                          frame_call_valid_r;
    logic                          frame_return_valid_r;

    // locals_base tracked by the frame module (drives decode).
    logic [RF_AW-1:0]              cur_locals_base_r;

    // One-cycle RF control pulses for frame transitions.
    logic                          rf_set_locals_r;
    logic [RF_AW-1:0]              rf_new_locals_r;
    logic                          rf_init_frame_r;

    // ---------------------------------------------------------------------
    // IF: instruction fetch
    // ---------------------------------------------------------------------
    logic                          if_instr_valid;
    logic [7:0]                    if_opcode;
    logic [31:0]                   if_arg;
    logic [31:0]                   if_pc;

    logic latch_instr;
    logic fetch_stall;
    assign latch_instr  = (state_r == S_FETCH) && if_instr_valid && !fetch_skip_r;
    assign fetch_stall  = (state_r != S_FETCH) || latch_instr;

    pycore_fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(IMEM_DATA_W)
    ) fetch (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .stall_i(fetch_stall),
        .flush_i(1'b0),
        .branch_taken_i(redirect_pending_r),
        .branch_target_i(redirect_tgt_r),
        .imem_req_o(imem_req_o),
        .imem_we_o(imem_we_o),
        .imem_addr_o(imem_addr_o),
        .imem_wdata_o(imem_wdata_o),
        .imem_ack_i(imem_ack_i),
        .imem_rdata_i(imem_rdata_i),
        .instr_valid_o(if_instr_valid),
        .opcode_o(if_opcode),
        .arg_o(if_arg),
        .pc_o(if_pc)
    );

    // ---------------------------------------------------------------------
    // ID: decode (pure combinational off the latched instruction + tos).
    // ---------------------------------------------------------------------
    logic [4:0]  dec_alu_op;
    logic [7:0]  dec_rs1_sel;
    logic [7:0]  dec_rs2_sel;
    logic [7:0]  dec_rd_sel;
    logic        dec_is_branch;
    logic        dec_is_call;
    logic        dec_is_return;
    logic        dec_is_container;
    logic        dec_push;
    logic        dec_pop;
    logic [2:0]  dec_mem_op;
    logic        dec_illegal;
    logic [31:0] dec_pc;

    pycore_decode decode (
        .instr_valid_i(1'b1),
        .opcode_i(cur_opcode_r),
        .arg_i(cur_arg_r),
        .pc_i(cur_pc_r),
        .tos_index_i(tos_r[7:0]),
        .locals_base_i(cur_locals_base_r[7:0]),
        .decoded_valid_o(),
        .alu_op_o(dec_alu_op),
        .rs1_sel_o(dec_rs1_sel),
        .rs2_sel_o(dec_rs2_sel),
        .rd_sel_o(dec_rd_sel),
        .is_branch_o(dec_is_branch),
        .is_call_o(dec_is_call),
        .is_return_o(dec_is_return),
        .is_container_o(dec_is_container),
        .push_stack_o(dec_push),
        .pop_stack_o(dec_pop),
        .mem_op_o(dec_mem_op),
        .illegal_opcode_o(dec_illegal),
        .decoded_pc_o(dec_pc)
    );

    // Per-opcode writeback-enable and stack-pointer delta.
    // Container ops (BUILD_LIST, BUILD_MAP, STORE_SUBSCR, BINARY_OP/NB_SUBSCR)
    // bypass S_WB entirely; their TOS update happens in S_CONTAINER instead.
    // The id_tos_delta case still needs to list them to avoid a default-warning,
    // but the values here are never applied (S_WB is skipped for these).
    logic              id_rd_we;
    logic signed [2:0] id_tos_delta;
    always_comb begin
        id_rd_we     = 1'b0;
        id_tos_delta = 3'sd0;
        unique case (cur_opcode_r)
            PY_OP_LOAD_FAST, PY_OP_LOAD_FAST_BORROW, PY_OP_LOAD_FAST_CHECK: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            PY_OP_STORE_FAST: begin
                id_rd_we = 1'b1; id_tos_delta = -3'sd1;
            end
            // DELETE_FAST: write UNINIT into local oparg; net stack 0.
            PY_OP_DELETE_FAST: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd0;
            end
            PY_OP_LOAD_SMALL_INT: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            // COPY: duplicate stack[-oparg] onto TOS; one RF write, push +1.
            PY_OP_COPY: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            // LOAD_CONST / LOAD_GLOBAL / LOAD_NAME / STORE_NAME / STORE_GLOBAL
            // / SWAP / paired-FAST ops / LOAD_FAST_AND_CLEAR are container ops
            // (S_CONTAINER manages tos and RF writes).
            PY_OP_LOAD_CONST, PY_OP_LOAD_GLOBAL, PY_OP_LOAD_NAME,
            PY_OP_STORE_NAME, PY_OP_STORE_GLOBAL,
            PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW,
            PY_OP_LOAD_FAST_LOAD_FAST,
            PY_OP_LOAD_FAST_AND_CLEAR,
            PY_OP_STORE_FAST_LOAD_FAST,
            PY_OP_STORE_FAST_STORE_FAST,
            PY_OP_SWAP: begin
                id_rd_we = 1'b0; id_tos_delta = 3'sd0;
            end
            // PUSH_NULL: push sentinel {NULL, 0}, one RF write via WB stage.
            PY_OP_PUSH_NULL: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            // TO_BOOL / UNARY_NOT: rewrite TOS in place; net stack effect 0.
            PY_OP_TO_BOOL, PY_OP_UNARY_NOT: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd0;
            end
            // MAKE_FUNCTION: function ≡ code object; net effect 0 with no
            // rewrite required (code handle already at TOS).  Type check on
            // rs1 is handled in the EX stage via exec_type_trap_pulse.
            PY_OP_MAKE_FUNCTION: begin
                id_rd_we = 1'b0; id_tos_delta = 3'sd0;
            end
            PY_OP_BINARY_OP: begin
                // NB_SUBSCR routes to S_CONTAINER; arithmetic ops use S_WB.
                if (dec_is_container) begin
                    id_rd_we = 1'b0; id_tos_delta = 3'sd0;
                end else begin
                    id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
                end
            end
            PY_OP_COMPARE_OP, PY_OP_IS_OP: begin
                id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
            end
            PY_OP_POP_TOP, PY_OP_POP_ITER: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_RETURN_VALUE: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_POP_JUMP_IF_TRUE, PY_OP_POP_JUMP_IF_FALSE,
            PY_OP_POP_JUMP_IF_NONE, PY_OP_POP_JUMP_IF_NOT_NONE: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_MEM_LOAD_PTR: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd0;
            end
            PY_OP_MEM_STORE_PTR: begin
                id_tos_delta = -3'sd2;
            end
            // Container ops: TOS managed by S_CONTAINER, not S_WB.
            PY_OP_BUILD_LIST, PY_OP_BUILD_MAP, PY_OP_BUILD_SET, PY_OP_BUILD_TUPLE,
            PY_OP_STORE_SUBSCR: begin
                id_rd_we = 1'b0; id_tos_delta = 3'sd0;
            end
            default: begin
            end
        endcase
    end

    // Register-file read (asynchronous).
    // During S_CONTAINER the rs1 port is driven by container_rf_addr_r so the
    // container FSM can read arbitrary RF slots (BUILD_LIST elements, STORE_SUBSCR
    // value) without an extra RF read port.
    logic [PYCORE_ENTRY_WIDTH-1:0] rf_rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] rf_rs2;
    logic [RF_AW-1:0] rs1_addr_eff;
    // S_CONTAINER and S_CALL both drive container_rf_addr_r to walk RF
    // slots without a second read port (callable / null / STORE value).
    assign rs1_addr_eff = ((state_r == S_CONTAINER) || (state_r == S_CALL))
                          ? container_rf_addr_r
                          : dec_rs1_sel[RF_AW-1:0];

    // ---------------------------------------------------------------------
    // EX: execute fabric + branch unit
    // ---------------------------------------------------------------------
    logic is_alu;
    // NB_SUBSCR (BINARY_OP with oparg=PY_NBARG_SUBSCR) routes to S_CONTAINER,
    // not the execute fabric.  Exclude it from is_alu so exec.valid_i stays low
    // and no spurious trap fires.
    assign is_alu = ((cur_opcode_r == PY_OP_BINARY_OP) && !dec_is_container) ||
                    (cur_opcode_r == PY_OP_COMPARE_OP);

    logic [PYCORE_ENTRY_WIDTH-1:0] exec_result;
    logic                          exec_stall;
    logic                          exec_trap;
    logic [3:0]                    exec_trap_code;

    pycore_exec #(
        .STRING_HEX(STRING_HEX)
    ) exec (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .valid_i((state_r == S_EXEC) && is_alu),
        .alu_op_i(dec_alu_op),
        .rs1_i(rs1_r),
        .rs2_i(rs2_r),
        .result_o(exec_result),
        .stall_o(exec_stall),
        .trap_o(exec_trap),
        .trap_code_o(exec_trap_code)
    );

    logic        branch_take;
    logic [31:0] branch_tgt;
    logic        branch_trap;
    logic [3:0]  branch_trap_code;

    pycore_branch branch (
        .opcode_i(cur_opcode_r),
        .pc_i(cur_pc_r),
        .arg_i(cur_arg_r),
        .tos_entry_i(rs1_r),
        .take_branch_o(branch_take),
        .branch_target_o(branch_tgt),
        .trap_o(branch_trap),
        .trap_code_o(branch_trap_code)
    );

    logic [PYCORE_ENTRY_WIDTH-1:0] ex_entry;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_addr_entry;
    always_comb begin
        logic [3:0]  ex_rs1_tag;
        logic [63:0] ex_rs1_int;
        logic        ex_rs1_bool;
        ex_entry      = rs1_r;
        ex_addr_entry = '0;
        exec_type_trap_pulse = 1'b0;
        exec_mem_fault_pulse = 1'b0;
        ex_rs1_tag  = pycore_get_tag(rs1_r);
        ex_rs1_int  = rs1_r[63:0];
        ex_rs1_bool = 1'b0;
        unique case (cur_opcode_r)
            PY_OP_LOAD_SMALL_INT: ex_entry = pycore_int_entry({32'b0, cur_arg_r});
            PY_OP_BINARY_OP, PY_OP_COMPARE_OP: ex_entry = exec_result;
            PY_OP_MEM_LOAD_PTR: begin
                ex_entry      = rs1_r;
                ex_addr_entry = rs1_r;
            end
            PY_OP_MEM_STORE_PTR: begin
                ex_entry      = rs1_r;
                ex_addr_entry = rs2_r;
            end
            // PUSH_NULL: emit the self_or_null sentinel entry.
            PY_OP_PUSH_NULL: ex_entry = pycore_make_entry(PY_TAG_NULL, '0);
            // DELETE_FAST: clear local to UNINIT; already-unbound → MEM_FAULT.
            PY_OP_DELETE_FAST: begin
                if (ex_rs1_tag == PY_TAG_UNINIT) begin
                    exec_mem_fault_pulse = (state_r == S_EXEC);
                end
                ex_entry = pycore_make_entry(PY_TAG_UNINIT, '0);
            end
            // LOAD_FAST_CHECK: push local like LOAD_FAST; unbound → MEM_FAULT.
            PY_OP_LOAD_FAST_CHECK: begin
                if (ex_rs1_tag == PY_TAG_UNINIT) begin
                    exec_mem_fault_pulse = (state_r == S_EXEC);
                end
                ex_entry = rs1_r;
            end
            // TO_BOOL: convert INT / BOOL / FLOAT to BOOL in place; anything
            // else raises PY_TRAP_TYPE via exec_type_trap_pulse.
            PY_OP_TO_BOOL: begin
                unique case (ex_rs1_tag)
                    PY_TAG_INT:   ex_rs1_bool = (rs1_r[PYCORE_VAL_MSB:0] != {PYCORE_VAL_WIDTH{1'b0}});
                    PY_TAG_BOOL:  ex_rs1_bool = ex_rs1_int[0];
                    PY_TAG_FLOAT: ex_rs1_bool = (ex_rs1_int[62:0] != 63'b0);
                    default: begin
                        ex_rs1_bool          = 1'b0;
                        exec_type_trap_pulse = (state_r == S_EXEC);
                    end
                endcase
                ex_entry = pycore_make_entry(PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, ex_rs1_bool});
            end
            // UNARY_NOT: invert TOS BOOL in place; non-BOOL → PY_TRAP_TYPE.
            PY_OP_UNARY_NOT: begin
                if (ex_rs1_tag == PY_TAG_BOOL) begin
                    ex_rs1_bool = !ex_rs1_int[0];
                end else begin
                    ex_rs1_bool          = 1'b0;
                    exec_type_trap_pulse = (state_r == S_EXEC);
                end
                ex_entry = pycore_make_entry(PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, ex_rs1_bool});
            end
            // IS_OP: full RF-entry identity → BOOL; oparg[0]=1 inverts (is not).
            PY_OP_IS_OP: begin
                ex_rs1_bool = (rs1_r == rs2_r);
                if (cur_arg_r[0]) begin
                    ex_rs1_bool = !ex_rs1_bool;
                end
                ex_entry = pycore_make_entry(PY_TAG_BOOL, {{(PYCORE_VAL_WIDTH-1){1'b0}}, ex_rs1_bool});
            end
            // MAKE_FUNCTION: function is the code object itself; verify tag.
            PY_OP_MAKE_FUNCTION: begin
                if (ex_rs1_tag != PY_TAG_CODE_OBJECT) begin
                    exec_type_trap_pulse = (state_r == S_EXEC);
                end
                ex_entry = rs1_r;
            end
            default: ex_entry = rs1_r;
        endcase
    end

    // ---------------------------------------------------------------------
    // MEM stage — drives its own dmem signals via intermediate wires so that
    // S_CALL can override them for register-spill writes.
    // ---------------------------------------------------------------------
    logic                          mem_wb_we;
    logic [PYCORE_ENTRY_WIDTH-1:0] mem_wb_entry;
    logic                          mem_stall;
    logic                          mem_trap;
    logic [3:0]                    mem_trap_code;

    // Intermediate wires: mem_stage drives these; mux below selects.
    logic                   ms_dmem_req;
    logic                   ms_dmem_we;
    logic [ADDR_WIDTH-1:0]  ms_dmem_addr;
    logic [DMEM_DATA_W-1:0] ms_dmem_wdata;

    pycore_mem_stage #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DMEM_DATA_W(DMEM_DATA_W)
    ) mem_stage (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .valid_i(state_r == S_MEM),
        .mem_op_i(dec_mem_op),
        .rd_we_in_i(id_rd_we),
        .alu_entry_i(ex_entry_r),
        .addr_entry_i(ex_addr_entry_r),
        .dmem_req_o(ms_dmem_req),
        .dmem_we_o(ms_dmem_we),
        .dmem_addr_o(ms_dmem_addr),
        .dmem_wdata_o(ms_dmem_wdata),
        .dmem_ack_i(dmem_ack_i),
        .dmem_rdata_i(dmem_rdata_i),
        .dmem_fault_i(dmem_fault_i),
        .wb_we_o(mem_wb_we),
        .wb_entry_o(mem_wb_entry),
        .mem_stall_o(mem_stall),
        .mem_trap_o(mem_trap),
        .mem_trap_code_o(mem_trap_code)
    );

    // ---------------------------------------------------------------------
    // Frame manager (pycore_frame).
    // On CALL the current frame descriptor {pc_return, tos_base, locals_base,
    // cur_code} is pushed to a DRAM stack as two 128-bit slots. On RETURN the
    // two slots are popped back and the core reloads caller code-object fields.
    // The core mediates those dmem transactions through the push/pop handshake.
    //
    // The frame stack lives in the upper half of the 16 KB data memory
    // (byte addresses 0x2000–0x3FFF), leaving the lower 8 KB for user-level
    // pointer data.  STACK_BASE_ADDR must be within the dmem address window
    // (BLOCK_COUNT × 2^BLOCK_SHIFT = 4 × 4 KB = 16 KB).
    // ---------------------------------------------------------------------
    localparam int    RF_BASE_CORE          = STACK_BASE;
    localparam int    MAX_CALL_DEPTH_CORE   = 128;
    localparam logic [ADDR_WIDTH-1:0] FRAME_STACK_BASE = 32'h0000_2000;
    localparam int    FRAME_STACK_BYTES     = 32'h0000_2000;  // 8 KB, 256 frames

    logic [RF_AW-1:0]      frame_next_locals_base;
    logic                  frame_init_new_frame;
    logic                  frame_return_done;
    logic                  frame_fault_sig;
    logic                  frame_busy;
    logic [31:0]           frame_pc_return_out;
    logic [RF_AW-1:0]      frame_tos_base_out;
    logic [RF_AW-1:0]      frame_locals_base_out;
    logic [31:0]           frame_cur_code_out;
    logic [$clog2(MAX_CALL_DEPTH_CORE+1)-1:0] frame_active_depth;

    // Push handshake (CALL path).
    logic                         frame_push_req;
    logic [ADDR_WIDTH-1:0]        frame_push_addr;
    logic [DMEM_DATA_W-1:0]       frame_push_data;
    // Pop handshake (RETURN path).
    logic                         frame_pop_req;
    logic [ADDR_WIDTH-1:0]        frame_pop_addr;

    // Combinational acks: asserted to the frame module the same cycle
    // dmem_ack_i fires, keeping pop_data = dmem_rdata_i valid at that posedge.
    logic frame_push_ack;
    logic frame_pop_ack;
    assign frame_push_ack = (state_r == S_CALL)   && frame_dmem_pending_r && dmem_ack_i;
    assign frame_pop_ack  = (state_r == S_RETURN) && frame_dmem_pending_r && dmem_ack_i;

    pycore_frame #(
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE_CORE),
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH_CORE),
        .STACK_BASE_ADDR(FRAME_STACK_BASE),
        .STACK_SIZE_BYTES(FRAME_STACK_BYTES)
    ) frame_mgr (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .call_valid_i(frame_call_valid_r),
        .return_valid_i(frame_return_valid_r),
        // CALL descriptor.  pc_return = pc(CALL) + 1: fetch skips the trailing
        // CACHE units (opcode 0) after redirecting on return so this points
        // one code-unit past the CALL slot itself.
        .pc_return_in_i(cur_pc_r + 32'd1),
        .tos_base_in_i(call_tos_base_r),
        .locals_base_in_i(cur_locals_base_r),
        .cur_code_in_i(cur_code_r),
        .new_locals_base_in_i(call_new_locals_r),
        .pc_return_out_o(frame_pc_return_out),
        .tos_base_out_o(frame_tos_base_out),
        .locals_base_out_o(frame_locals_base_out),
        .cur_code_out_o(frame_cur_code_out),
        .next_locals_base_o(frame_next_locals_base),
        .init_new_frame_o(frame_init_new_frame),
        .return_done_o(frame_return_done),
        .active_frames_out_o(frame_active_depth),
        .head_ptr_out_o(),
        .tail_ptr_out_o(),
        .frame_fault_o(frame_fault_sig),
        .frame_busy_o(frame_busy),
        .push_req_o(frame_push_req),
        .push_addr_o(frame_push_addr),
        .push_data_o(frame_push_data),
        .push_ack_i(frame_push_ack),
        .pop_req_o(frame_pop_req),
        .pop_addr_o(frame_pop_addr),
        .pop_data_i(dmem_rdata_i[DMEM_DATA_W-1:0]),
        .pop_ack_i(frame_pop_ack)
    );

    // ---------------------------------------------------------------------
    // Register file.  push_stack / pop_stack are left idle.
    // The return_wb path lets S_RETURN place the callee's return value
    // onto the caller's stack in the cycle after frame_return_done fires.
    // ---------------------------------------------------------------------
    logic [RF_AW-1:0]              rf_rd_addr_mux;
    logic [PYCORE_ENTRY_WIDTH-1:0] rf_rd_data_mux;
    logic rf_we;
    // Priority: container_wb > return_wb > normal S_WB path.
    // container_wb_we_r and return_wb_we_r are one-cycle pulses that fire
    // in S_FETCH (the cycle after S_CONTAINER/S_RETURN commits).
    assign rf_we          = ((state_r == S_WB) && wb_we_r && !freeze_pipeline) ||
                            return_wb_we_r || container_wb_we_r;
    assign rf_rd_addr_mux = container_wb_we_r ? container_wb_addr_r :
                            return_wb_we_r    ? return_wb_addr_r    :
                                                dec_rd_sel[RF_AW-1:0];
    assign rf_rd_data_mux = container_wb_we_r ? container_wb_data_r :
                            return_wb_we_r    ? rs1_r               :
                                                wb_entry_r;
    assign dbg_wb_we_o    = rf_we;
    assign dbg_wb_addr_o  = 8'(rf_rd_addr_mux);
    assign dbg_wb_entry_o = rf_rd_data_mux;

    pycore_regfile #(
        .RF_DEPTH(RF_DEPTH)
    ) regfile (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .rs1_addr_i(rs1_addr_eff),
        .rs2_addr_i(dec_rs2_sel[RF_AW-1:0]),
        .rs1_o(rf_rs1),
        .rs2_o(rf_rs2),
        .rd_we_i(rf_we),
        .rd_addr_i(rf_rd_addr_mux),
        .rd_i(rf_rd_data_mux),
        .set_locals_base_i(rf_set_locals_r),
        .new_locals_base_i(rf_new_locals_r),
        .init_frame_i(rf_init_frame_r),
        .push_stack_i(1'b0),
        .pop_stack_i(1'b0),
        .tos_ptr_o(),
        .locals_base_o(),
        .stack_fault_o()
    );

    // ---------------------------------------------------------------------
    // Dmem mux: three sources share the single dmem port.
    //   1. frame_dmem_active (S_CALL / S_RETURN): frame push/pop.
    //   2. container_dmem_active: heap alloc / element R/W (S_CONTAINER)
    //      AND boot-record + code-object field reads (S_BOOT, S_CALL,
    //      S_RETURN before frame_dmem_pending_r goes high).
    //   3. ms_dmem_* (S_MEM): normal PTR load/store.
    // Only one of container_dmem_pending_r / frame_dmem_pending_r may be
    // high at a time (the FSM issues them sequentially); S_MEM never
    // overlaps with 1 or 2.
    // ---------------------------------------------------------------------
    logic frame_dmem_active;
    logic container_dmem_active;
    assign frame_dmem_active     = frame_dmem_pending_r &&
                                   ((state_r == S_CALL) || (state_r == S_RETURN));
    assign container_dmem_active = container_dmem_pending_r &&
                                   ((state_r == S_CONTAINER) ||
                                    (state_r == S_BOOT)      ||
                                    (state_r == S_CALL)      ||
                                    (state_r == S_RETURN));

    assign dmem_req_o   = frame_dmem_active     ? 1'b1 :
                          container_dmem_active ? 1'b1 : ms_dmem_req;
    assign dmem_we_o    = frame_dmem_active     ? (state_r == S_CALL) :
                          container_dmem_active ? container_dmem_we_r  : ms_dmem_we;
    assign dmem_addr_o  = frame_dmem_active     ?
                              ((state_r == S_CALL) ? frame_push_addr : frame_pop_addr) :
                          container_dmem_active ? container_dmem_addr_r  : ms_dmem_addr;
    assign dmem_wdata_o = frame_dmem_active     ? frame_push_data :
                          container_dmem_active ? container_dmem_wdata_r : ms_dmem_wdata;

    // ---------------------------------------------------------------------
    // Trap aggregation (single in-flight instruction).
    // ---------------------------------------------------------------------
    logic        freeze_pipeline;
    logic signed [9:0] next_tos;
    assign next_tos = $signed({2'b0, tos_r}) + id_tos_delta;

    logic type_trap_sig;
    logic stack_fault_sig;
    logic div_zero_sig;
    logic fpu_exc_sig;
    logic illegal_sig;
    logic mem_fault_sig;
    logic addr_align_sig;
    logic list_grow_sig;
    logic frame_fault_trap_sig;

    logic exec_in;
    logic mem_in;
    assign exec_in = (state_r == S_EXEC);
    assign mem_in  = (state_r == S_MEM);

    // container_type_trap_r / container_mem_fault_r are one-cycle pulses set in
    // S_CONTAINER's always_ff when a type or bounds error is detected.
    // exec_type_trap_pulse folds in MAKE_FUNCTION (non-CODE_OBJECT),
    // TO_BOOL (non-numeric), and UNARY_NOT (non-BOOL) type checks that ride
    // the EX stage combinationally.
    // exec_mem_fault_pulse covers DELETE_FAST on an already-unbound local
    // and LOAD_FAST_CHECK on an unbound local (UnboundLocalError analog →
    // PY_TRAP_MEM_FAULT).
    logic exec_type_trap_pulse;
    logic exec_mem_fault_pulse;
    assign type_trap_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_TYPE)) ||
                            (exec_in && dec_is_branch && branch_trap) ||
                            exec_type_trap_pulse ||
                            container_type_trap_r;
    assign stack_fault_sig = (state_r == S_WB) && !dec_is_call && !dec_is_return &&
                              !dec_is_container &&
                             ((next_tos < STACK_BASE) || (next_tos > STACK_TOP_MAX));
    assign div_zero_sig   = exec_in && exec_trap && (exec_trap_code == PY_TRAP_DIV_ZERO);
    assign fpu_exc_sig    = exec_in && exec_trap && (exec_trap_code == PY_TRAP_FPU_EXCEPTION);
    assign illegal_sig    = (exec_in && dec_illegal) ||
                            (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ILLEGAL_OPCODE));
    assign mem_fault_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_MEM_FAULT)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_MEM_FAULT)) ||
                            exec_mem_fault_pulse ||
                            container_mem_fault_r ||
                            imem_fault_i;
    assign addr_align_sig = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ADDR_ALIGN)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_ADDR_ALIGN));
    // CONT_LIST_APPEND raises this before any RF/heap commit (see
    // CP_HDR).  Phase A/B report it fatally; Phase C's S_TRAP_MARSHAL
    // intercepts pycore_trap_recoverable() codes before they ever reach
    // this signal when EXCORE_EN is set.
    assign list_grow_sig  = container_list_grow_trap_r;
    logic list_extend_sig;
    assign list_extend_sig = container_list_extend_trap_r;
    logic dict_grow_sig;
    logic dict_collision_sig;
    logic list_delete_sig;
    logic set_grow_sig;
    logic set_update_sig;
    assign dict_grow_sig      = container_dict_grow_trap_r;
    assign dict_collision_sig = container_dict_collision_trap_r; // unused stub
    assign list_delete_sig    = container_list_delete_trap_r;
    assign set_grow_sig       = container_set_grow_trap_r;
    assign set_update_sig     = container_set_update_trap_r;
    // Phase C: excore reported RES_FATAL for a trap it was handed — forward
    // its fatal_code as a normal halt (see S_TRAP_WAIT).
    logic excore_fatal_sig;
    assign excore_fatal_sig = excore_fatal_trap_r;
    // Frame faults and CALL preflight failures both report as PY_TRAP_CALL_FILTER.
    assign frame_fault_trap_sig = (state_r == S_CALL || state_r == S_RETURN) &&
                                  frame_fault_sig;

    logic [31:0]                   fault_pc;
    logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs2;
    assign fault_pc  = cur_pc_r;
    assign fault_rs1 = (state_r == S_MEM) ? ex_addr_entry_r : rs1_r;
    assign fault_rs2 = (state_r == S_MEM) ? ex_entry_r : rs2_r;

    pycore_trap trap_block (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .type_trap_i(type_trap_sig),
        .stack_fault_i(stack_fault_sig),
        .div_zero_i(div_zero_sig),
        .fpu_exception_i(fpu_exc_sig),
        .illegal_opcode_i(illegal_sig),
        .call_filter_i(call_filter_trap_r || frame_fault_trap_sig),
        .mem_fault_i(mem_fault_sig),
        .addr_align_i(addr_align_sig),
        .list_grow_i(list_grow_sig),
        .list_extend_i(list_extend_sig),
        .dict_grow_i(dict_grow_sig),
        .list_delete_i(list_delete_sig),
        .dict_collision_i(dict_collision_sig),
        .set_grow_i(set_grow_sig),
        .set_update_i(set_update_sig),
        .excore_fatal_i(excore_fatal_sig),
        .excore_fatal_code_i(excore_fatal_code_r),
        .fault_pc_i(fault_pc),
        .fault_rs1_i(fault_rs1),
        .fault_rs2_i(fault_rs2),
        .trap_out_o(trap_out_o),
        .trap_code_o(trap_code_o),
        .trap_pc_o(),
        .trap_rs1_o(),
        .trap_rs2_o(),
        .freeze_pipeline_o(freeze_pipeline)
    );

    // -------------------------------------------------------------------------
    // S_TRAP_MARSHAL / S_TRAP_WAIT (Phase C) combinational wiring.
    // -------------------------------------------------------------------------
    // trap_req_valid_o is a level tied directly to state_r, not a register:
    // the mailbox handshake (trap_req_ready_i) is what advances us out of
    // S_TRAP_MARSHAL, so there is nothing to latch beyond what the
    // container op already staged in trap_marshal_*_r.
    assign trap_req_valid_o        = (state_r == S_TRAP_MARSHAL);
    assign trap_req_code_o         = trap_marshal_code_r;
    assign trap_req_pc_o           = cur_pc_r;
    assign trap_req_instr_o        = {cur_arg_r, cur_opcode_r};
    assign trap_req_heap_ptr_o     = heap_ptr_r;
    assign trap_req_entry_count_o  = trap_marshal_entry_count_r;
    assign trap_req_entries_o      = trap_marshal_entries_r;

    // trap_wait_ready: all of S_TRAP_WAIT's local work (latch result, pop,
    // sequence push_count writes) has committed; gates both the exit from
    // S_TRAP_WAIT (always_comb above) and the trap_res handshake ack.
    logic trap_wait_ready;
    assign trap_wait_ready  = trap_res_seen_r &&
                              (trap_wait_push_idx_r >= {1'b0, trap_res_push_r});
    assign trap_res_ready_o = (state_r == S_TRAP_WAIT) && trap_wait_ready;

    // -------------------------------------------------------------------------
    // Combinational helpers for S_CONTAINER.
    // Computed from latched registers so always_ff can read them without
    // needing part-selects on function return values (which Verilator rejects
    // inside always_ff blocks).
    // -------------------------------------------------------------------------
    logic [127:0] cont_rs1_val;   // value field of rs1_r (container handle etc.)
    logic [127:0] cont_rs2_val;   // value field of rs2_r (key etc.)
    logic [31:0]  cont_rs1_addr;  // lower 32 bits of rs1 value (heap address)
    logic [31:0]  cont_rs2_addr;  // lower 32 bits of rs2 value
    logic [63:0]  cont_key_u;     // key value as unsigned 64-bit (rs2 or rs1 for STORE_SUBSCR)
    logic [63:0]  cont_key_u_st;  // key for STORE_SUBSCR (from rs1_r)
    logic [63:0]  cont_hdr_len;   // list length from last header read
    logic [63:0]  cont_hdr_cap;   // list capacity from last header read
    // Resolved buffer address from the last ob_item slot read
    // (container_rd_data_r = {64'd0, ob_item}).  Function-call results
    // cannot be part-selected directly inside always_ff (Verilator parser
    // limitation), so this wire exists purely to let CP_LIST_BUF phases
    // read a 32-bit address without an inline slice.
    logic [63:0]  cont_obitem_raw;
    logic [31:0]  cont_obitem_buf;
    // Resolved element index (list length) from the CONT_LIST_APPEND
    // header snapshot — same part-select restriction as cont_obitem_buf.
    logic [63:0]  cont_list_append_idx_raw;
    logic [31:0]  cont_list_append_idx;
    logic [31:0]  cont_bl_alloc;  // bytes to allocate for BUILD_LIST (object + buffer)
    logic [31:0]  cont_bt_alloc;  // bytes to allocate for BUILD_TUPLE
    logic [63:0]  cont_tuple_size;// inline size from TUPLE handle (rs1)
    logic [3:0]   cont_rs1_tag;   // tag of rs1_r
    logic [3:0]   cont_rs2_tag;   // tag of rs2_r
    logic [127:0] cont_rf_rs1_val; // value field of rf_rs1 (container RF read)
    logic [3:0]   cont_rf_rs1_tag; // tag of rf_rs1

    assign cont_rs1_val   = pycore_get_val(rs1_r);
    assign cont_rs2_val   = pycore_get_val(rs2_r);
    assign cont_rs1_addr  = cont_rs1_val[31:0];
    assign cont_rs2_addr  = cont_rs2_val[31:0];
    assign cont_key_u     = cont_rs2_val[63:0];   // SUBSCR_*: key = rs2
    assign cont_key_u_st  = cont_rs1_val[63:0];   // STORE_SUBSCR: key = rs1
    assign cont_hdr_len   = pycore_list_length(container_rd_data_r);
    assign cont_hdr_cap   = pycore_list_capacity(container_rd_data_r);
    assign cont_obitem_raw = pycore_list_obitem(container_rd_data_r);
    assign cont_obitem_buf = cont_obitem_raw[31:0];
    assign cont_list_append_idx_raw = pycore_list_length(container_list_hdr_r);
    assign cont_list_append_idx = cont_list_append_idx_raw[31:0];
    // Object (32B, fixed) + buffer (count*32B; 0 for the empty-list case,
    // matching the count==0 early-exit that skips buffer allocation).
    assign cont_bl_alloc  = pycore_list_obj_bytes() +
                            ((container_count_r == 7'd0) ? 32'd0 :
                             pycore_list_buf_bytes({25'b0, container_count_r}));
    assign cont_bt_alloc  = pycore_tuple_alloc_bytes({25'b0, container_count_r});
    assign cont_tuple_size = pycore_tuple_size(cont_rs1_val);
    // LIST_EXTEND: iterable is rs2 — tuple size/addr come from its handle.
    logic [63:0]  cont_tuple_size_rs2;
    logic [31:0]  cont_tuple_addr_rs2;
    logic [63:0]  cont_ext_hdr_len;
    logic [63:0]  cont_ext_hdr_cap;
    logic [31:0]  cont_ext_dst_idx; // dst_len + copy idx for writes
    assign cont_tuple_size_rs2 = pycore_tuple_size(cont_rs2_val);
    assign cont_tuple_addr_rs2 = cont_rs2_val[31:0];
    assign cont_ext_hdr_len    = pycore_list_length(container_list_hdr_r);
    assign cont_ext_hdr_cap    = pycore_list_capacity(container_list_hdr_r);
    assign cont_ext_dst_idx    = container_dst_len_r + {25'b0, container_idx_r};
    assign cont_rs1_tag   = pycore_get_tag(rs1_r);
    assign cont_rs2_tag   = pycore_get_tag(rs2_r);
    assign cont_rf_rs1_val = pycore_get_val(rf_rs1);
    assign cont_rf_rs1_tag = pycore_get_tag(rf_rs1);

    // Dict-specific combinational helpers.
    // Slot count computed from container_count_r (pairs), used during BUILD_MAP init.
    logic [31:0] cont_dict_min_slots;
    assign cont_dict_min_slots = pycore_dict_min_slots(container_count_r);

    // Dict header fields (from last header read).
    logic [63:0] cont_dict_hdr_slots;
    logic [63:0] cont_dict_hdr_used;
    assign cont_dict_hdr_slots = pycore_dict_slot_count_from_hdr(container_rd_data_r);
    assign cont_dict_hdr_used  = pycore_dict_used_from_hdr(container_rd_data_r);

    // Linear-probe hash of the currently active search key (in container_val_r /
    // container_tag_r). Only valid when container_slot_count_r is non-zero.
    logic [31:0] cont_dict_hash;
    assign cont_dict_hash = pycore_dict_key_hash(container_tag_r, container_val_r)
                          & (container_slot_count_r - 32'd1);

    // Hash for a key in rs2 (NB_SUBSCR) and rs1 (STORE_SUBSCR).
    logic [31:0] cont_dict_hash_rs2;
    logic [31:0] cont_dict_hash_rs1;
    assign cont_dict_hash_rs2 = pycore_dict_key_hash(cont_rs2_tag, cont_rs2_val)
                              & (container_slot_count_r - 32'd1);
    assign cont_dict_hash_rs1 = pycore_dict_key_hash(cont_rs1_tag, cont_rs1_val)
                              & (container_slot_count_r - 32'd1);

    // Key comparison against the last kval read (container_rd_data_r).
    // INT: compare value[63:0]. BOOL: compare value[0].
    // Probe key/element match via rich equality (INT/BOOL/FLOAT cross-tag,
    // same-tag STR). Slot tag latched in container_probe_tag_r at PROBE;
    // slot value is container_rd_data_r at CHK_VAL. LONG_STR equality relies
    // on interning (known limitation for runtime-concatenated strings).
    logic cont_dict_key_match;
    assign cont_dict_key_match = pycore_dict_key_rich_eq(
        container_tag_r, container_val_r,
        container_probe_tag_r, container_rd_data_r);

    logic cont_set_needs_grow;
    assign cont_set_needs_grow = pycore_set_needs_grow(
        container_used_r, {32'b0, container_slot_count_r});

    logic [31:0] cont_set_min_slots;
    assign cont_set_min_slots = pycore_set_min_slots(container_count_r);

    // Load-factor / empty-table check before a new-key dict insert.
    logic cont_dict_needs_grow;
    assign cont_dict_needs_grow = pycore_dict_needs_grow(
        container_used_r, {32'b0, container_slot_count_r});

    // table_ptr low 32 bits from the last table_ptr-slot dmem read.
    logic [31:0] cont_dict_table_ptr;
    assign cont_dict_table_ptr = container_rd_data_r[31:0];

    // CONTAINS_OP: compare scanned element (value latched in container_val_r,
    // tag in container_rd_data_r[3:0] during CP_TAG) against needle rs1.
    logic cont_contains_eq;
    assign cont_contains_eq = pycore_elem_eq(
        container_rd_data_r[3:0], container_val_r,
        cont_rs1_tag, cont_rs1_val);

    // Probe advance: (probe + 1) & mask.
    logic [31:0] cont_probe_next;
    assign cont_probe_next = (container_probe_r + 32'd1) & (container_slot_count_r - 32'd1);

    // ---------------------------------------------------------------------
    // Control FSM — next-state combinational logic.
    // state_r is the registered current state; state_next is the combinational
    // next state, computed every cycle and sampled on the next rising edge.
    // ---------------------------------------------------------------------
    logic [3:0] state_next;
    // (container_done_r removed: all operations advance container_phase_r to
    // CP_DONE as the terminal marker; the always_comb checks that directly.)

    // Terminal marker for S_CALL / S_RETURN / S_BOOT.  Each of these states
    // sets its own phase counter to a well-known "done" value in the cycle
    // that commits state to the RF / fetch redirect.  Using a phase-driven
    // exit (rather than a wire from the frame module) keeps the extra
    // code-object dmem reads inside the same state.
    localparam logic [3:0] CALL_PHASE_DONE = 4'd15;
    localparam logic [2:0] RET_PHASE_DONE  = 3'd7;
    localparam logic [3:0] BOOT_PHASE_DONE = 4'd15;

    always_comb begin
        state_next = state_r;  // default: hold current state

        if (freeze_pipeline) begin
            state_next = S_HALT;
        end else begin
            unique case (state_r)
                S_FETCH: begin
                    if (latch_instr) state_next = S_DECODE;
                end
                S_DECODE: begin
                    state_next = S_EXEC;
                end
                S_EXEC: begin
                    if (!exec_stall) begin
                        // Container ops bypass S_MEM and S_WB entirely.
                        if (dec_is_container) state_next = S_CONTAINER;
                        else                  state_next = S_MEM;
                    end
                end
                S_MEM: begin
                    if (!mem_stall) state_next = S_WB;
                end
                S_WB: begin
                    if (!dec_is_call && !dec_is_return) begin
                        state_next = S_FETCH;
                    end else if (dec_is_call) begin
                        state_next = S_CALL;
                    end else if (frame_active_depth > 0) begin
                        state_next = S_RETURN;
                    end else begin
                        state_next = S_FETCH;  // base-frame return
                    end
                end
                S_CALL: begin
                    // Multi-phase CALL: callable/null RF settle, four code-
                    // field dmem reads, frame push, then init.  Exit only
                    // after the whole sequence commits (CALL_PHASE_DONE).
                    if (call_phase_r == CALL_PHASE_DONE) state_next = S_FETCH;
                end
                S_RETURN: begin
                    // Multi-phase RETURN: frame pop, then two dmem reads to
                    // reload caller's co_consts / co_names before redirect.
                    if (return_phase_r == RET_PHASE_DONE) state_next = S_FETCH;
                end
                S_CONTAINER: begin
                    // CP_DONE is a terminal marker phase used uniformly by all
                    // sub-operations.  All actual work (RF write, TOS update) is
                    // committed in the cycle that advances container_phase_r to
                    // CP_DONE, so the CP_DONE always_ff case is intentionally empty.
                    // trap_marshal_pending_r (Phase C, EXCORE_EN=1) redirects the
                    // exit to S_TRAP_MARSHAL instead of S_FETCH.
                    if (container_phase_r == CP_DONE) begin
                        state_next = trap_marshal_pending_r ? S_TRAP_MARSHAL : S_FETCH;
                    end
                end
                S_TRAP_MARSHAL: begin
                    if (trap_req_ready_i) state_next = S_TRAP_WAIT;
                end
                S_TRAP_WAIT: begin
                    if (trap_wait_ready) begin
                        state_next = (trap_res_code_r2 == TRAP_RES_FATAL) ? S_HALT : S_FETCH;
                    end
                end
                S_BOOT: begin
                    if (boot_phase_r == BOOT_PHASE_DONE) state_next = S_FETCH;
                end
                S_HALT: begin
                    state_next = S_HALT;
                end
                default: state_next = S_FETCH;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Control FSM — sequential: register state_next and update data regs.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r                <= BOOT_EN ? S_BOOT : S_FETCH;
            cur_opcode_r           <= 8'b0;
            cur_arg_r              <= 32'b0;
            cur_pc_r               <= 32'b0;
            rs1_r                <= '0;
            rs2_r                <= '0;
            ex_entry_r           <= '0;
            ex_addr_entry_r      <= '0;
            branch_take_r        <= 1'b0;
            branch_tgt_r         <= 32'b0;
            wb_entry_r           <= '0;
            wb_we_r              <= 1'b0;
            tos_r                <= STACK_BASE[RF_AW-1:0];
            fetch_skip_r         <= 1'b0;
            redirect_pending_r   <= 1'b0;
            redirect_tgt_r       <= 32'b0;
            cycle_count_o          <= 64'b0;
            cur_locals_base_r      <= '0;  // base frame locals live in RF[0..31]
            call_sent_r          <= 1'b0;
            frame_dmem_pending_r <= 1'b0;
            frame_call_valid_r   <= 1'b0;
            frame_return_valid_r <= 1'b0;
            rf_set_locals_r      <= 1'b0;
            rf_new_locals_r      <= '0;
            rf_init_frame_r      <= 1'b0;
            return_wb_we_r       <= 1'b0;
            return_wb_addr_r     <= '0;
            // Arch regs for image boot.
            cur_code_r           <= '0;
            consts_base_r        <= '0;
            names_base_r         <= '0;
            globals_base_r       <= '0;
            call_phase_r         <= '0;
            return_phase_r       <= '0;
            boot_phase_r         <= '0;
            call_code_addr_r     <= '0;
            call_entry_slot_r    <= '0;
            call_consts_r        <= '0;
            call_names_r         <= '0;
            call_argcount_r      <= '0;
            call_nlocals_r       <= '0;
            call_new_locals_r    <= '0;
            call_tos_base_r      <= '0;
            call_filter_trap_r   <= 1'b0;
            // Container / heap allocator reset.
            heap_ptr_r               <= HEAP_INIT_PTR;
            container_op_r           <= '0;
            container_phase_r        <= '0;
            container_idx_r          <= '0;
            container_count_r        <= '0;
            container_base_r         <= '0;
            container_tag_r          <= '0;
            container_val_r          <= '0;
            container_rf_addr_r      <= '0;
            container_rd_data_r      <= '0;
            container_slot_count_r   <= '0;
            container_probe_r        <= '0;
            container_val_rf_addr_r  <= '0;
            container_used_r         <= '0;
            container_probe_n_r      <= '0;
            container_insert_new_r   <= 1'b0;
            container_finishing_r    <= 1'b0;
            container_push_null_r    <= 1'b0;
            container_lfb_hi_r       <= '0;
            container_lfb_lo_r       <= '0;
            container_dmem_pending_r <= 1'b0;
            container_dmem_addr_r    <= '0;
            container_dmem_we_r      <= 1'b0;
            container_dmem_wdata_r   <= '0;
            container_wb_we_r        <= 1'b0;
            container_wb_addr_r      <= '0;
            container_wb_data_r      <= '0;
            container_type_trap_r    <= 1'b0;
            container_mem_fault_r    <= 1'b0;
            container_buf_r          <= '0;
            container_list_hdr_r     <= '0;
            container_list_grow_trap_r   <= 1'b0;
            container_src_buf_r          <= '0;
            container_src_len_r          <= '0;
            container_dst_len_r          <= '0;
            container_list_extend_trap_r <= 1'b0;
            container_list_delete_trap_r <= 1'b0;
            container_dict_grow_trap_r      <= 1'b0;
            container_dict_collision_trap_r <= 1'b0;
            container_set_grow_trap_r       <= 1'b0;
            container_set_update_trap_r     <= 1'b0;
            container_probe_tag_r           <= '0;
            container_tomb_valid_r          <= 1'b0;
            container_tomb_idx_r            <= '0;
            trap_marshal_pending_r     <= 1'b0;
            trap_marshal_code_r        <= '0;
            trap_marshal_entry_count_r <= '0;
            trap_marshal_entries_r[0]  <= '0;
            trap_marshal_entries_r[1]  <= '0;
            trap_marshal_entries_r[2]  <= '0;
            trap_wait_push_idx_r       <= '0;
            trap_res_seen_r            <= 1'b0;
            trap_res_code_r2           <= '0;
            trap_res_fatal_r2          <= '0;
            trap_res_push_r            <= '0;
            trap_res_entries_r2[0]     <= '0;
            trap_res_entries_r2[1]     <= '0;
            excore_fatal_trap_r        <= 1'b0;
            excore_fatal_code_r        <= '0;
        end else begin
            state_r <= state_next;  // register next state (computed in always_comb)

            cycle_count_o        <= cycle_count_o + 1'b1;

            // Clear one-cycle pulses by default.
            frame_call_valid_r   <= 1'b0;
            frame_return_valid_r <= 1'b0;
            rf_set_locals_r      <= 1'b0;
            rf_init_frame_r      <= 1'b0;
            return_wb_we_r       <= 1'b0;
            container_wb_we_r     <= 1'b0;
            container_type_trap_r <= 1'b0;
            container_mem_fault_r <= 1'b0;
            container_list_grow_trap_r   <= 1'b0;
            container_list_extend_trap_r <= 1'b0;
            container_list_delete_trap_r <= 1'b0;
            container_dict_grow_trap_r      <= 1'b0;
            container_dict_collision_trap_r <= 1'b0;
            container_set_grow_trap_r       <= 1'b0;
            container_set_update_trap_r     <= 1'b0;
            excore_fatal_trap_r   <= 1'b0;
            call_filter_trap_r    <= 1'b0;

            if (state_r == S_FETCH) begin
                redirect_pending_r <= 1'b0;
            end

            unique case (state_r)

                // ----------------------------------------------------------
                S_FETCH: begin
                    if (latch_instr) begin
                        cur_opcode_r       <= if_opcode;
                        cur_arg_r          <= if_arg;
                        cur_pc_r           <= if_pc;
                        // state_next = S_DECODE (from always_comb)
                    end else if (!if_instr_valid) begin
                        fetch_skip_r <= 1'b0;
                    end
                end

                // ----------------------------------------------------------
                S_DECODE: begin
                    rs1_r <= rf_rs1;
                    rs2_r <= rf_rs2;
                    // state_next = S_EXEC (from always_comb)
                end

                // ----------------------------------------------------------
                S_EXEC: begin
                    if (!exec_stall) begin
                        ex_entry_r      <= ex_entry;
                        ex_addr_entry_r <= ex_addr_entry;
                        branch_take_r   <= branch_take;
                        branch_tgt_r    <= branch_tgt;

                        // Container-op initialization: runs whenever S_EXEC
                        // transitions to S_CONTAINER (dec_is_container).
                        // Decode which sub-operation we are entering and
                        // pre-clear the dmem/trap handshake registers.
                        if (dec_is_container) begin
                            container_phase_r        <= CP_INIT;
                            container_dmem_pending_r <= 1'b0;
                            container_type_trap_r    <= 1'b0;
                            container_mem_fault_r    <= 1'b0;
                            container_wb_we_r        <= 1'b0;
                            trap_marshal_pending_r   <= 1'b0;

                            if (cur_opcode_r == PY_OP_BUILD_LIST) begin
                                container_op_r    <= CONT_BUILD_LIST;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_BUILD_MAP) begin
                                container_op_r    <= CONT_BUILD_MAP;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_BUILD_SET) begin
                                container_op_r    <= CONT_BUILD_SET;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_BUILD_TUPLE) begin
                                container_op_r    <= CONT_BUILD_TUPLE;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_STORE_SUBSCR) begin
                                // rs2 = container; choose LIST vs DICT path.
                                // TUPLE (immutable) falls through to CONT_STORE_LIST,
                                // which type-traps on non-LIST.
                                container_op_r <= (cont_rs2_tag == PY_TAG_DICT) ?
                                                  CONT_STORE_DICT : CONT_STORE_LIST;
                            end else if (cur_opcode_r == PY_OP_DELETE_SUBSCR) begin
                                // DICT → tombstone path; LIST → shift-down;
                                // SET / other → TYPE in CONT_DELETE_LIST.
                                container_op_r <= (cont_rs2_tag == PY_TAG_DICT) ?
                                                  CONT_DELETE_DICT : CONT_DELETE_LIST;
                            end else if (cur_opcode_r == PY_OP_CONTAINS_OP) begin
                                // rs1 = needle, rs2 = container.
                                if (cont_rs2_tag == PY_TAG_DICT)
                                    container_op_r <= CONT_CONTAINS_DICT;
                                else if (cont_rs2_tag == PY_TAG_SET)
                                    container_op_r <= CONT_CONTAINS_SET;
                                else if (cont_rs2_tag == PY_TAG_TUPLE)
                                    container_op_r <= CONT_CONTAINS_TUPLE;
                                else
                                    container_op_r <= CONT_CONTAINS_LIST;
                            end else if (cur_opcode_r == PY_OP_LOAD_CONST) begin
                                container_op_r <= CONT_LOAD_CONST;
                            end else if (cur_opcode_r == PY_OP_LOAD_GLOBAL) begin
                                container_op_r        <= CONT_LOAD_GLOBAL;
                                container_push_null_r <= cur_arg_r[0];
                            end else if (cur_opcode_r == PY_OP_LOAD_NAME) begin
                                // Same lookup path as LOAD_GLOBAL but no NULL push.
                                container_op_r        <= CONT_LOAD_GLOBAL;
                                container_push_null_r <= 1'b0;
                            end else if ((cur_opcode_r == PY_OP_STORE_NAME) ||
                                         (cur_opcode_r == PY_OP_STORE_GLOBAL)) begin
                                container_op_r <= CONT_STORE_NAME;
                            end else if ((cur_opcode_r ==
                                          PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW) ||
                                         (cur_opcode_r ==
                                          PY_OP_LOAD_FAST_LOAD_FAST)) begin
                                // LFLF shares CONT_LFB_PAIR (borrow≡owned).
                                container_op_r     <= CONT_LFB_PAIR;
                                container_lfb_hi_r <= cur_arg_r[7:4];
                                container_lfb_lo_r <= cur_arg_r[3:0];
                            end else if (cur_opcode_r == PY_OP_LIST_APPEND) begin
                                container_op_r <= CONT_LIST_APPEND;
                            end else if (cur_opcode_r == PY_OP_LIST_EXTEND) begin
                                container_op_r <= CONT_LIST_EXTEND;
                            end else if (cur_opcode_r == PY_OP_SET_ADD) begin
                                container_op_r <= CONT_SET_ADD;
                            end else if (cur_opcode_r == PY_OP_SET_UPDATE) begin
                                container_op_r <= CONT_SET_UPDATE;
                            end else if (cur_opcode_r ==
                                         PY_OP_STORE_FAST_LOAD_FAST) begin
                                container_op_r     <= CONT_SFLF;
                                container_lfb_hi_r <= cur_arg_r[7:4];
                                container_lfb_lo_r <= cur_arg_r[3:0];
                            end else if (cur_opcode_r ==
                                         PY_OP_STORE_FAST_STORE_FAST) begin
                                container_op_r     <= CONT_SFSF;
                                container_lfb_hi_r <= cur_arg_r[7:4];
                                container_lfb_lo_r <= cur_arg_r[3:0];
                            end else if (cur_opcode_r ==
                                         PY_OP_LOAD_FAST_AND_CLEAR) begin
                                // CONT_LFAC: rs1_r = latched local value.
                                container_op_r <= CONT_LFAC;
                            end else if (cur_opcode_r == PY_OP_SWAP) begin
                                container_op_r <= CONT_SWAP;
                            end else if (cur_opcode_r == PY_OP_BINARY_OP) begin
                                // BINARY_OP/NB_SUBSCR: rs1 = container.
                                if (cont_rs1_tag == PY_TAG_DICT)
                                    container_op_r <= CONT_SUBSCR_DICT;
                                else if (cont_rs1_tag == PY_TAG_TUPLE)
                                    container_op_r <= CONT_SUBSCR_TUPLE;
                                else
                                    container_op_r <= CONT_SUBSCR_LIST;
                            end
                        end
                        // state_next = S_MEM or S_CONTAINER (from always_comb)
                    end
                end

                // ----------------------------------------------------------
                S_MEM: begin
                    if (!mem_stall) begin
                        wb_entry_r <= mem_wb_entry;
                        wb_we_r    <= mem_wb_we;
                        // state_next = S_WB (from always_comb)
                    end
                end

                // ----------------------------------------------------------
                S_WB: begin
                    if (!dec_is_call && !dec_is_return) begin
                        // Normal instruction writeback.
                        tos_r <= next_tos[RF_AW-1:0];
                        if (dec_is_branch && branch_take_r) begin
                            redirect_pending_r <= 1'b1;
                            redirect_tgt_r     <= branch_tgt_r;
                        end
                        fetch_skip_r <= 1'b1;
                        // state_next = S_FETCH (from always_comb)

                    end else if (dec_is_call) begin
                        // CALL: move to multi-phase frame-management state.
                        // Phase 0 → RF settle at callable slot.
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        call_phase_r         <= 4'd0;
                        container_dmem_pending_r <= 1'b0;
                        fetch_skip_r         <= 1'b1;
                        // state_next = S_CALL (from always_comb)

                    end else begin
                        // RETURN_VALUE.
                        if (frame_active_depth > 0) begin
                            // There is a calling frame: pop the frame, reload
                            // caller consts/names, then redirect.
                            call_sent_r          <= 1'b0;
                            frame_dmem_pending_r <= 1'b0;
                            return_phase_r       <= 3'd0;
                            container_dmem_pending_r <= 1'b0;
                            fetch_skip_r <= 1'b1;
                            // state_next = S_RETURN (from always_comb)
                        end else begin
                            // Base-frame return: no caller exists.  Just pop
                            // the TOS and resume fetching.
                            tos_r        <= next_tos[RF_AW-1:0];
                            fetch_skip_r <= 1'b1;
                            // state_next = S_FETCH (from always_comb)
                        end
                    end
                end

                // ----------------------------------------------------------
                // S_CALL: real CPython CALL, multi-phase.
                //
                //   Layout at CALL entry with argc=arg:
                //     callable @ RF[tos - argc - 2]
                //     null      @ RF[tos - argc - 1]
                //     args      @ RF[tos - argc .. tos - 1]
                //
                //   Phase  0: settle rf_addr = callable slot.
                //   Phase  1: latch callable; type-check CODE_OBJECT.
                //             Set rf_addr = null slot.
                //   Phase  2: latch null; type-check PY_TAG_NULL.
                //             Issue dmem read of code_field 0 (entry_slot).
                //   Phase  3: latch entry_slot; issue field 1 (co_consts).
                //   Phase  4: latch consts; issue field 2 (co_names).
                //   Phase  5: latch names; issue field 3 (metadata).
                //   Phase  6: latch metadata; argcount check.  Pulse
                //             frame_call_valid_r and drive the frame push
                //             beat0.
                //   Phase  7: mirror old-style frame-push handshake until
                //             init_new_frame_o.  On init, commit callee
                //             cur_code / consts / names / locals_base and
                //             redirect fetch to entry_slot.
                //   Phase 15: terminal marker; state_next → S_FETCH.
                //
                // A single dmem transaction is in flight at a time.  The
                // container_dmem_* handshake is reused for code-field reads.
                // ----------------------------------------------------------
                S_CALL: begin
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        container_rd_data_r      <= dmem_rdata_i;
                    end

                    unique case (call_phase_r)

                        4'd0: begin
                            // Compute helper indices; kick RF read for callable.
                            call_new_locals_r <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                            call_tos_base_r   <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                            container_rf_addr_r <= RF_AW'(
                                {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd2);
                            call_phase_r <= 4'd1;
                        end

                        4'd1: begin
                            // rf_rs1 = callable — check tag CODE_OBJECT.
                            if (cont_rf_rs1_tag != PY_TAG_CODE_OBJECT) begin
                                call_filter_trap_r <= 1'b1;
                            end else begin
                                call_code_addr_r    <= cont_rf_rs1_val[31:0];
                                container_rf_addr_r <= RF_AW'(
                                    {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]} - 9'd1);
                                call_phase_r        <= 4'd2;
                            end
                        end

                        4'd2: begin
                            // rf_rs1 = null sentinel.
                            if (cont_rf_rs1_tag != PY_TAG_NULL) begin
                                call_filter_trap_r <= 1'b1;
                            end else begin
                                // Issue field 0 (entry_slot) VAL read.
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_ENTRY_SLOT);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd3;
                            end
                        end

                        4'd3: begin
                            if (!container_dmem_pending_r) begin
                                call_entry_slot_r <= container_rd_data_r[63:0];
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd4;
                            end
                        end

                        4'd4: begin
                            if (!container_dmem_pending_r) begin
                                call_consts_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd5;
                            end
                        end

                        4'd5: begin
                            if (!container_dmem_pending_r) begin
                                call_names_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    call_code_addr_r, PYCORE_CODE_FIELD_METADATA);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                call_phase_r             <= 4'd6;
                            end
                        end

                        4'd6: begin
                            if (!container_dmem_pending_r) begin
                                call_argcount_r <= pycore_code_meta_argcount(container_rd_data_r);
                                call_nlocals_r  <= pycore_code_meta_nlocals(container_rd_data_r);
                                // Argcount preflight: mismatched arity → CALL_FILTER.
                                if (pycore_code_meta_argcount(container_rd_data_r)
                                    != cur_arg_r[15:0]) begin
                                    call_filter_trap_r <= 1'b1;
                                end else if ((9'(call_new_locals_r)
                                              + 9'(pycore_code_meta_nlocals(
                                                    container_rd_data_r)))
                                             > 9'(STACK_TOP_MAX)) begin
                                    call_filter_trap_r <= 1'b1;
                                end else begin
                                    call_phase_r <= 4'd7;
                                end
                            end
                        end

                        4'd7: begin
                            // Frame push mirrors the previous single-phase impl.
                            if (!call_sent_r && !frame_busy) begin
                                frame_call_valid_r   <= 1'b1;
                                call_sent_r          <= 1'b1;
                            end

                            if (call_sent_r && frame_push_req && !frame_dmem_pending_r) begin
                                frame_dmem_pending_r <= 1'b1;
                            end

                            if (frame_dmem_pending_r && dmem_ack_i) begin
                                frame_dmem_pending_r <= 1'b0;
                            end

                            if (frame_init_new_frame) begin
                                cur_locals_base_r    <= frame_next_locals_base;
                                rf_set_locals_r      <= 1'b1;
                                rf_new_locals_r      <= frame_next_locals_base;
                                rf_init_frame_r      <= (call_argcount_r == 16'd0);
                                tos_r                <= frame_next_locals_base
                                                        + call_nlocals_r[6:0];
                                call_sent_r          <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                // Commit callee code-object caches.
                                cur_code_r           <= call_code_addr_r;
                                consts_base_r        <= call_consts_r;
                                names_base_r         <= call_names_r;
                                redirect_pending_r   <= 1'b1;
                                redirect_tgt_r       <= call_entry_slot_r[31:0];
                                call_phase_r         <= CALL_PHASE_DONE;
                            end
                        end

                        default: ;
                    endcase
                end

                // ----------------------------------------------------------
                // S_RETURN: pop caller frame, re-read consts/names for the
                // restored code object, then commit return value at tos_base
                // and redirect fetch to pc_return.
                //
                //   Phase 0: frame pop handshake (mirrors prior impl).
                //            On return_done_o: cur_code_r <= frame_cur_code_out.
                //            Issue dmem read of consts VAL from restored code.
                //   Phase 1: latch consts; issue names VAL read.
                //   Phase 2: latch names; commit return value, redirect fetch.
                //   Phase 7: terminal marker.
                // ----------------------------------------------------------
                S_RETURN: begin
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        container_rd_data_r      <= dmem_rdata_i;
                    end

                    unique case (return_phase_r)

                        3'd0: begin
                            if (!call_sent_r && !frame_busy) begin
                                frame_return_valid_r <= 1'b1;
                                call_sent_r          <= 1'b1;
                            end

                            if (call_sent_r && frame_pop_req && !frame_dmem_pending_r) begin
                                frame_dmem_pending_r <= 1'b1;
                            end

                            if (frame_dmem_pending_r && dmem_ack_i) begin
                                frame_dmem_pending_r <= 1'b0;
                            end

                            if (frame_return_done) begin
                                // Latch restored caller state.
                                cur_locals_base_r    <= frame_locals_base_out;
                                rf_set_locals_r      <= 1'b1;
                                rf_new_locals_r      <= frame_locals_base_out;
                                cur_code_r           <= frame_cur_code_out;
                                call_tos_base_r      <= frame_tos_base_out;
                                call_entry_slot_r    <= {32'b0, frame_pc_return_out};
                                call_sent_r          <= 1'b0;
                                frame_dmem_pending_r <= 1'b0;
                                // Kick consts VAL read from restored code.
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    frame_cur_code_out, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                return_phase_r <= 3'd1;
                            end
                        end

                        3'd1: begin
                            if (!container_dmem_pending_r) begin
                                consts_base_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                return_phase_r <= 3'd2;
                            end
                        end

                        3'd2: begin
                            if (!container_dmem_pending_r) begin
                                names_base_r <= container_rd_data_r;
                                // Commit return value at caller's tos_base.
                                return_wb_we_r     <= 1'b1;
                                return_wb_addr_r   <= call_tos_base_r;
                                tos_r              <= call_tos_base_r + RF_AW'(1);
                                redirect_pending_r <= 1'b1;
                                redirect_tgt_r     <= call_entry_slot_r[31:0];
                                return_phase_r     <= RET_PHASE_DONE;
                            end
                        end

                        default: ;
                    endcase
                end

                // ----------------------------------------------------------
                // S_CONTAINER: multi-cycle handler for container operations.
                //
                // Sub-phases (container_phase_r):
                //
                //   BUILD_LIST(count) — allocates the stable OBJECT (32B) and
                //   the element BUFFER (count*32B) in one combined OOM check
                //   (list layout v2, Phase A):
                //     CP_INIT     : OOM check (object + buffer); write header
                //                   {count, count} to the object; set RF addr.
                //     CP_HDR      : ack of header write → write ob_item
                //                   (buffer address, 0 if count==0).
                //     CP_LIST_BUF : ack of ob_item write → empty-list early
                //                   exit, or save RF data and write element
                //                   value into the buffer.
                //     CP_VAL      : ack of value write  → write tag.
                //     CP_TAG      : ack of tag write    → idx++, loop back to
                //                   CP_LIST_BUF, or CP_DONE.
                //     CP_DONE     : terminal marker; always_comb → S_FETCH.
                //
                //   BINARY_OP / NB_SUBSCR (list read) — one extra ob_item
                //   read between the header and the element access:
                //     CP_INIT     : check types; start header read.
                //     CP_HDR      : ack header → bounds check (against
                //                   length); start ob_item read.
                //     CP_LIST_BUF : ack ob_item → resolve buffer address;
                //                   start value read.
                //     CP_VAL      : ack value  → save value; start tag read.
                //     CP_TAG      : ack tag    → assemble result; pulse
                //                   wb/TOS/done.
                //
                //   STORE_SUBSCR (list write) — same ob_item indirection:
                //     CP_INIT     : check types; set RF addr for value;
                //                   start header read.
                //     CP_HDR      : ack header → bounds check; start ob_item
                //                   read.
                //     CP_LIST_BUF : ack ob_item → resolve buffer address;
                //                   read RF value; write value.
                //     CP_VAL      : ack value  → write tag.
                //     CP_TAG      : ack tag    → update TOS, go to S_FETCH.
                //
                //   LIST_APPEND (fast path only — Phase A; see
                //   CONT_LIST_APPEND below for the full state list and the
                //   PY_TRAP_LIST_GROW early-trap discipline).
                //
                //   BUILD_MAP / SUBSCR_DICT / STORE_DICT: see CONT_* cases below.
                //   BUILD_TUPLE / SUBSCR_TUPLE: like LIST without a header slot.
                // ----------------------------------------------------------
                S_CONTAINER: begin

                    // ---- dmem ack: shared clearing --------------------------
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        // Save read data for header and tag reads.
                        container_rd_data_r <= dmem_rdata_i;
                    end

                    // ---- Per-operation phase logic --------------------------
                    unique case (container_op_r)

                        // =====================================================
                        CONT_BUILD_LIST: begin
                            unique case (container_phase_r)

                                // Phase 0 (CP_INIT): check OOM (object + buffer
                                // together) and issue the object's header write.
                                CP_INIT: begin
                                    // OOM check: object (32B) + buffer (count*32B,
                                    // 0 for the empty-list case).
                                    if ((heap_ptr_r + cont_bl_alloc) > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        // Object base (stable handle target).
                                        container_base_r       <= heap_ptr_r;
                                        // Buffer base immediately follows the 32B
                                        // object; irrelevant (never read) when
                                        // count==0, where ob_item is written 0.
                                        container_buf_r         <= heap_ptr_r + 32'd32;
                                        // Issue header write: {capacity, length}.
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_list_header(
                                            {57'b0, container_count_r},
                                            {57'b0, container_count_r});
                                        container_dmem_pending_r <= 1'b1;
                                        // Advance heap_ptr by the full allocation
                                        // now — capacity == count exactly (no
                                        // over-allocation), matching CPython
                                        // list-literal semantics.
                                        heap_ptr_r             <= heap_ptr_r + cont_bl_alloc;
                                        // Pre-load RF address for element 0.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_idx_r        <= 7'd0;
                                        container_phase_r      <= CP_HDR;
                                    end
                                end

                                // Phase 1 (CP_HDR): wait for header-write ack,
                                // then write ob_item (buffer address, or 0 for
                                // an empty list — no buffer allocation).
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_list_obitem_addr(
                                            container_base_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {64'b0,
                                            (container_count_r == 7'd0) ? 32'd0 : container_buf_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_LIST_BUF;
                                    end
                                end

                                // Phase 2 (CP_LIST_BUF): wait for ob_item-write
                                // ack.  Empty list: commit handle now.  Non-empty
                                // (also reached by looping back from CP_TAG for
                                // element i>0): RF address settled; issue the
                                // element value write against the buffer base.
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            // Empty list: object only, ob_item=0.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_LIST,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Save element from RF (async read valid now).
                                            container_tag_r        <= cont_rf_rs1_tag;
                                            container_val_r        <= cont_rf_rs1_val;
                                            // Issue element value write into the buffer.
                                            container_dmem_addr_r  <= pycore_list_val_addr(
                                                container_buf_r,
                                                {25'b0, container_idx_r});
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= cont_rf_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r      <= CP_VAL;
                                        end
                                    end
                                end

                                // Phase 3 (CP_VAL): wait for element value-write ack.
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Issue element tag write.
                                        container_dmem_addr_r  <= pycore_list_tag_addr(
                                            container_buf_r,
                                            {25'b0, container_idx_r});
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                // Phase 4 (CP_TAG): wait for element tag-write ack.
                                // When all elements are written, commit the list
                                // handle here (in the same ack cycle) and advance
                                // to CP_DONE, which is an intentionally empty
                                // terminal phase that triggers S_FETCH transition.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            // More elements: advance to next, and
                                            // loop back to CP_LIST_BUF (no dmem op
                                            // is pending, so the guard there passes
                                            // immediately and issues the next
                                            // element's value write).
                                            container_idx_r     <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r}
                                                + 9'd1);
                                            container_phase_r   <= CP_LIST_BUF;
                                        end else begin
                                            // All elements written — commit list.
                                            // Push {PY_TAG_LIST, 0, base} to RF[tos-count].
                                            // heap_ptr already advanced by exactly
                                            // cont_bl_alloc back in CP_INIT.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_LIST,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r            <= tos_r
                                                - {2'b0, container_count_r} + 7'd1;
                                            fetch_skip_r     <= 1'b1;
                                            // Advance to terminal phase; always_comb
                                            // transitions to S_FETCH when phase=CP_DONE.
                                            container_phase_r   <= CP_DONE;
                                        end
                                    end
                                end

                                // Phase 5 (CP_DONE): terminal marker — do nothing.
                                // All commit work was done in CP_TAG / empty
                                // CP_LIST_BUF.  The always_comb state-next logic
                                // transitions to S_FETCH the same cycle
                                // container_phase_r=CP_DONE.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_BUILD_LIST

                        // =====================================================
                        CONT_SUBSCR_LIST: begin
                            // rs1_r = container (PY_TAG_LIST expected)
                            // rs2_r = key       (INT or BOOL expected)
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // Type checks.
                                    if (cont_rs1_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag != PY_TAG_INT &&
                                                 cont_rs2_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        // Issue header read (object address).
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = header {capacity, length}.
                                        // Bounds check: 0 <= key < length.
                                        if (cont_key_u >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            // Read ob_item (buffer address).
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        container_buf_r <= cont_obitem_buf;
                                        // Read element value from the buffer.
                                        container_dmem_addr_r <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_key_u[31:0]);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Save value, read tag.
                                        container_val_r       <= container_rd_data_r;
                                        // Compute tag address: val_addr + 16.
                                        container_dmem_addr_r <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r   <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r     <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Assemble result and write back to RF.
                                        // Tag is in container_rd_data_r[3:0].
                                        // Result lands at tos-2 (container slot).
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        // Pop 1 (key): tos-2 keeps the result.
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        // Advance to terminal marker to prevent
                                        // this branch from executing a second time
                                        // while the FSM lingers in S_CONTAINER.
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                // State transitions to S_FETCH via always_comb.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_SUBSCR_LIST

                        // =====================================================
                        CONT_STORE_LIST: begin
                            // rs1_r = key       (INT or BOOL)
                            // rs2_r = container (PY_TAG_LIST)
                            // value at RF[tos-3] (read via container_rf_addr_r)
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // Type checks.
                                    if (cont_rs2_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs1_tag != PY_TAG_INT &&
                                                 cont_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        // Set RF address to read value (tos-3).
                                        container_rf_addr_r      <= RF_AW'(tos_r - RF_AW'(3));
                                        // Start header read (object address).
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // RF[tos-3] value now valid (addr set last cycle).
                                        // Bounds check using cont_key_u_st (key is rs1).
                                        if (cont_key_u_st >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            // Read ob_item (buffer address).
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        // Save value from RF (addr settled since
                                        // CP_INIT; unaffected by the intervening
                                        // header/ob_item reads).
                                        container_buf_r         <= cont_obitem_buf;
                                        container_tag_r        <= cont_rf_rs1_tag;
                                        container_val_r        <= cont_rf_rs1_val;
                                        // Write value slot into the buffer.
                                        container_dmem_addr_r  <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_key_u_st[31:0]);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= cont_rf_rs1_val;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Write tag slot.
                                        container_dmem_addr_r  <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Pop 3 (key, container, value).
                                        tos_r             <= tos_r - RF_AW'(3);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_STORE_LIST

                        // =====================================================
                        // CONT_DELETE_LIST: DELETE_SUBSCR on a LIST.
                        // rs1_r = key (INT/BOOL); rs2_r = list handle.
                        // Type/bounds on pycore. Last element (idx == len-1):
                        // O(1) length-- on pycore. Shift (idx < len-1): raise
                        // PY_TRAP_LIST_DELETE before any commit; excore shifts
                        // and COMPLETED pop=2. Non-LIST → TYPE.
                        // =====================================================
                        CONT_DELETE_LIST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs2_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs1_tag != PY_TAG_INT &&
                                                 cont_rs1_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        // Delete index from key (rs1).
                                        if (cont_key_u_st >= cont_hdr_len) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_dst_len_r <= cont_key_u_st[31:0];
                                            // Last element: length-- only (no
                                            // shift). Mid delete: trap before
                                            // any commit (no ob_item needed).
                                            if (cont_key_u_st + 64'd1
                                                    == cont_hdr_len) begin
                                                container_dmem_addr_r  <=
                                                    container_base_r;
                                                container_dmem_we_r     <= 1'b1;
                                                container_dmem_wdata_r  <=
                                                    pycore_list_header(
                                                        cont_hdr_cap,
                                                        cont_hdr_len - 64'd1);
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r       <=
                                                    CP_LIST_WB;
                                            end else if (EXCORE_EN &&
                                                pycore_trap_recoverable(
                                                    PY_TRAP_LIST_DELETE)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <=
                                                    PY_TRAP_LIST_DELETE;
                                                trap_marshal_entry_count_r <= 3'd2;
                                                trap_marshal_entries_r[0]  <= rs2_r;
                                                trap_marshal_entries_r[1]  <= rs1_r;
                                                container_phase_r          <=
                                                    CP_DONE;
                                            end else begin
                                                container_list_delete_trap_r <=
                                                    1'b1;
                                            end
                                        end
                                    end
                                end

                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        tos_r             <= tos_r - RF_AW'(2);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_DELETE_LIST

                        // =====================================================
                        // CONT_LIST_APPEND: fast path only (Phase A).  When the
                        // list has spare capacity, append in place; when full,
                        // raise PY_TRAP_LIST_GROW *before* any RF/heap/dmem
                        // commit (checked in CP_HDR, before the ob_item read) so
                        // the operation is safely restartable — a prerequisite
                        // for the future excore RETRY contract (Phase C), even
                        // though Phase A always treats this trap as fatal.
                        //
                        //   rs1_r = list handle (RF[tos-1-arg], PY_TAG_LIST)
                        //   rs2_r = element     (RF[tos-1], popped on success)
                        //
                        //   CP_INIT     : type-check rs1; start header read.
                        //   CP_HDR      : ack header → snapshot {cap,length}
                        //                 into container_list_hdr_r (it must
                        //                 survive the ob_item read's overwrite
                        //                 of container_rd_data_r); length<cap →
                        //                 read ob_item, else PY_TRAP_LIST_GROW.
                        //   CP_LIST_BUF : ack ob_item → resolve buffer address;
                        //                 write element value at buf+length*32.
                        //   CP_VAL      : ack value write → write element tag.
                        //   CP_TAG      : ack tag write → write back header
                        //                 {cap, length+1}.
                        //   CP_LIST_WB  : ack header write → pop 1 (element);
                        //                 done.
                        // =====================================================
                        CONT_LIST_APPEND: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_hdr_len < cont_hdr_cap) begin
                                            // Fast path: spare capacity exists.
                                            // Snapshot the header now — it will
                                            // be needed again at CP_TAG, after
                                            // container_rd_data_r has been
                                            // overwritten by the ob_item read.
                                            container_list_hdr_r  <= container_rd_data_r;
                                            container_dmem_addr_r <= pycore_list_obitem_addr(
                                                container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end else if (EXCORE_EN &&
                                                     pycore_trap_recoverable(PY_TRAP_LIST_GROW)) begin
                                            // Full, but the excore can service
                                            // this: marshal the operands it
                                            // needs (list handle + element —
                                            // exactly rs1_r/rs2_r, already
                                            // decoded for this op) and hand off
                                            // instead of halting.  No RF, heap,
                                            // or dmem-write commit has happened.
                                            trap_marshal_pending_r    <= 1'b1;
                                            trap_marshal_code_r       <= PY_TRAP_LIST_GROW;
                                            trap_marshal_entry_count_r <= 3'd2;
                                            trap_marshal_entries_r[0] <= rs1_r; // list handle
                                            trap_marshal_entries_r[1] <= rs2_r; // element
                                            container_phase_r         <= CP_DONE;
                                        end else begin
                                            // Full, no excore: raise the fatal
                                            // grow trap (Phase A/B behavior).
                                            // No RF, heap, or dmem-write commit
                                            // has happened.
                                            container_list_grow_trap_r <= 1'b1;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        // container_rd_data_r = {0, ob_item}.
                                        container_buf_r        <= cont_obitem_buf;
                                        container_tag_r         <= cont_rs2_tag;
                                        container_dmem_addr_r   <= pycore_list_val_addr(
                                            cont_obitem_buf,
                                            cont_list_append_idx);
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= cont_rs2_val;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_list_tag_addr(
                                            container_buf_r,
                                            cont_list_append_idx);
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r     <= 1'b1;
                                        container_dmem_wdata_r  <= pycore_list_header(
                                            pycore_list_capacity(container_list_hdr_r),
                                            pycore_list_length(container_list_hdr_r) + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r       <= CP_LIST_WB;
                                    end
                                end

                                CP_LIST_WB: begin
                                    if (!container_dmem_pending_r) begin
                                        // Pop 1 (the appended element); the list
                                        // handle beneath it is left in place.
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_LIST_APPEND

                        // =====================================================
                        // CONT_LIST_EXTEND: extend dst list from a LIST or TUPLE
                        // source. Empty source is a no-op pop on pycore.
                        // Non-empty always raises PY_TRAP_LIST_EXTEND (excore
                        // grows-to-fit or in-place copies when capacity
                        // already sufficient). Unsupported iterable → TYPE.
                        //
                        //   rs1_r = list handle (RF[tos-1-arg])
                        //   rs2_r = iterable    (RF[tos-1], popped)
                        // =====================================================
                        CONT_LIST_EXTEND: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag != PY_TAG_LIST &&
                                                 cont_rs2_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        // Snapshot dst header (unused for the
                                        // trap path; kept for empty/self checks).
                                        container_list_hdr_r <= container_rd_data_r;
                                        container_dst_len_r  <= cont_hdr_len[31:0];
                                        if (cont_rs2_tag == PY_TAG_TUPLE) begin
                                            container_src_len_r <=
                                                cont_tuple_size_rs2[31:0];
                                            container_phase_r <= CP_SRC_HDR;
                                        end else if (cont_rs2_addr == cont_rs1_addr) begin
                                            // Self-extend: src_len = dst len.
                                            container_src_len_r <= cont_hdr_len[31:0];
                                            container_phase_r   <= CP_SRC_HDR;
                                        end else begin
                                            // Distinct list source: read header.
                                            container_dmem_addr_r    <= cont_rs2_addr;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_SRC_HDR;
                                        end
                                    end
                                end

                                CP_SRC_HDR: begin
                                    // Wait for distinct-list src header if needed.
                                    if (cont_rs2_tag == PY_TAG_LIST &&
                                        cont_rs2_addr != cont_rs1_addr &&
                                        container_dmem_pending_r) begin
                                        // Still waiting on src header.
                                    end else begin
                                        if (cont_rs2_tag == PY_TAG_LIST &&
                                            cont_rs2_addr != cont_rs1_addr &&
                                            !container_dmem_pending_r) begin
                                            container_src_len_r <= cont_hdr_len[31:0];
                                        end
                                        // Empty source → no-op pop. Non-empty
                                        // → always LIST_EXTEND (before commit).
                                        if ((cont_rs2_tag == PY_TAG_LIST &&
                                             cont_rs2_addr != cont_rs1_addr)
                                            ? (cont_hdr_len == 64'd0)
                                            : (container_src_len_r == 32'd0)) begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (EXCORE_EN &&
                                            pycore_trap_recoverable(
                                                PY_TRAP_LIST_EXTEND)) begin
                                            trap_marshal_pending_r     <= 1'b1;
                                            trap_marshal_code_r        <=
                                                PY_TRAP_LIST_EXTEND;
                                            trap_marshal_entry_count_r <= 3'd2;
                                            trap_marshal_entries_r[0]  <= rs1_r;
                                            trap_marshal_entries_r[1]  <= rs2_r;
                                            container_phase_r          <= CP_DONE;
                                        end else begin
                                            container_list_extend_trap_r <= 1'b1;
                                        end
                                    end
                                end

                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_LIST_EXTEND

                        // ===========================================================
                        // CONT_BUILD_MAP: allocate dict (32B obj + contiguous table)
                        // + linear-probe insert all pairs. Layout v2: slot helpers
                        // take table base in container_buf_r. Probe uses rich_eq
                        // (same-tag + INT/BOOL/FLOAT cross). Fresh bump-heap
                        // words are zero → UNINIT empty slots.
                        // ===========================================================
                        CONT_BUILD_MAP: begin
                            unique case (container_phase_r)

                                // Phase 0: OOM check, allocate header + table.
                                CP_INIT: begin
                                    if ((heap_ptr_r + pycore_dict_alloc_bytes(cont_dict_min_slots))
                                            > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_slot_count_r <= cont_dict_min_slots;
                                        container_used_r       <= 64'd0;
                                        container_probe_n_r    <= 32'd0;
                                        container_insert_new_r <= 1'b0;
                                        container_finishing_r  <= 1'b0;
                                        container_base_r       <= heap_ptr_r;
                                        // Contiguous table immediately after 32B object.
                                        container_buf_r        <= heap_ptr_r + 32'd32;
                                        heap_ptr_r             <= heap_ptr_r +
                                            pycore_dict_alloc_bytes(cont_dict_min_slots);
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, cont_dict_min_slots}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        // Pre-set RF addr to first pair's key.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r, 1'b0});
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                // Phase 1: header write ack → write table_ptr,
                                // or finish used-count rewrite / empty commit.
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            // Final used-count header rewrite acked → commit.
                                            container_finishing_r <= 1'b0;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_DICT,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r <= tos_r
                                                - {2'b0, container_count_r, 1'b0}
                                                + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Install table_ptr at obj+16 (0 only
                                            // if slot_count were 0; BUILD_MAP always
                                            // allocates ≥4 slots via min_slots).
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {{64{1'b0}}, {32'b0, container_buf_r}};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                // Phase 2: table_ptr write ack → probe or empty done.
                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_DICT, {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_tag_r <= cont_rf_rs1_tag;
                                            container_val_r <= cont_rf_rs1_val;
                                            if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                container_val_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r}
                                                    - {2'b0, container_count_r, 1'b0}
                                                    + 9'd1);
                                                begin
                                                    logic [31:0] probe0;
                                                    probe0 = pycore_dict_key_hash(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val)
                                                        & (container_slot_count_r - 32'd1);
                                                    container_probe_r   <= probe0;
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, probe0);
                                                end
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_PROBE;
                                            end
                                        end
                                    end
                                end

                                // Probe: occupied → rich_eq at CHK_VAL.
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                // BUILD_MAP: treat tombstone like occupied
                                                // mismatch — continue (should not appear).
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_dict_kval_addr(
                                                        container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_used_r <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                        end
                                        container_rf_addr_r <= container_val_rf_addr_r;
                                        container_phase_r   <= CP_DICT_RD_VAL;
                                    end
                                end

                                CP_DICT_RD_VAL: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0}
                                                + {2'b0, container_idx_r, 1'b0}
                                                + 9'd2);
                                            container_val_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r, 1'b0}
                                                + {2'b0, container_idx_r, 1'b0}
                                                + 9'd3);
                                            container_phase_r <= CP_DICT_HASH;
                                        end else begin
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r);
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end
                                    end
                                end

                                CP_DICT_HASH: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_val_r <= cont_rf_rs1_val;
                                    if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_probe_r   <= cont_dict_hash;
                                        container_probe_n_r <= 32'd0;
                                        container_dmem_addr_r <= pycore_dict_ktag_addr(
                                            container_buf_r, cont_dict_hash);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_PROBE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_MAP


                        // ===========================================================
                        // CONT_SUBSCR_DICT: dict key lookup (NB_SUBSCR on DICT handle).
                        // rs1_r = dict handle; rs2_r = key.
                        // Layout v2: CP_HDR → CP_LIST_BUF reads table_ptr into
                        // container_buf_r; slot helpers use the table base.
                        // Cross-tag numeric probe → DICT_COLLISION (before commit).
                        // ===========================================================
                        CONT_SUBSCR_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs2_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs2_tag;
                                        container_val_r <= cont_rs2_val;
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            // Empty dict → KeyError analog.
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <= pycore_dict_vval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_RD_VVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VTAG;
                                    end
                                end

                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0], container_val_r);
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_DICT


                        // ===========================================================
                        // CONT_STORE_DICT: dict key upsert (STORE_SUBSCR on DICT).
                        // rs1_r = key; rs2_r = dict handle; value = RF[tos-3]
                        // (latched via container_rf_addr_r set in CP_INIT so
                        // cont_rf_rs1_* is ready by grow/collision trap time).
                        // New-key insert at empty/tombstone: DICT_GROW when
                        // pycore_dict_needs_grow; else write. Cross-tag numeric
                        // → DICT_COLLISION before any commit.
                        // ===========================================================
                        CONT_STORE_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        // Point RF port at value early so grow /
                                        // collision marshal can assemble entry2.
                                        container_rf_addr_r     <= RF_AW'(tos_r - RF_AW'(3));
                                        container_val_rf_addr_r <= RF_AW'(tos_r - RF_AW'(3));
                                        container_insert_new_r  <= 1'b0;
                                        container_finishing_r   <= 1'b0;
                                        container_tomb_valid_r  <= 1'b0;
                                        container_tomb_idx_r    <= 32'd0;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(3);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            // Empty table → DICT_GROW before insert.
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <= rs2_r;
                                                trap_marshal_entries_r[1]  <= rs1_r;
                                                trap_marshal_entries_r[2]  <=
                                                    pycore_make_entry(cont_rf_rs1_tag,
                                                                      cont_rf_rs1_val);
                                                container_phase_r          <= CP_DONE;
                                            end else begin
                                                container_dict_grow_trap_r <= 1'b1;
                                            end
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            // Full probe without UNINIT: insert at
                                            // first tombstone if any, else fault.
                                            if (container_tomb_valid_r) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <= rs2_r;
                                                        trap_marshal_entries_r[1]  <= rs1_r;
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <= container_tomb_idx_r;
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <=
                                                        pycore_dict_kval_addr(
                                                            container_buf_r,
                                                            container_tomb_idx_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <= container_val_r;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_WR_KVAL;
                                                end
                                            end else begin
                                                // No empty/tombstone: grow.
                                                if (EXCORE_EN &&
                                                    pycore_trap_recoverable(
                                                        PY_TRAP_DICT_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_DICT_GROW;
                                                    trap_marshal_entry_count_r <= 3'd3;
                                                    trap_marshal_entries_r[0]  <= rs2_r;
                                                    trap_marshal_entries_r[1]  <= rs1_r;
                                                    trap_marshal_entries_r[2]  <=
                                                        pycore_make_entry(
                                                            cont_rf_rs1_tag,
                                                            cont_rf_rs1_val);
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_dict_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Insert at first tombstone or here.
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <= rs2_r;
                                                        trap_marshal_entries_r[1]  <= rs1_r;
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    begin
                                                        logic [31:0] ins;
                                                        ins = container_tomb_valid_r ?
                                                              container_tomb_idx_r :
                                                              container_probe_r;
                                                        container_probe_r      <= ins;
                                                        container_insert_new_r <= 1'b1;
                                                        container_dmem_addr_r  <=
                                                            pycore_dict_kval_addr(
                                                                container_buf_r, ins);
                                                        container_dmem_we_r    <= 1'b1;
                                                        container_dmem_wdata_r <=
                                                            container_val_r;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r <= CP_DICT_WR_KVAL;
                                                    end
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <= container_probe_r;
                                                end
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    // Fall through next cycle via
                                                    // probe_n >= slot_count path.
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Overwrite existing key — used unchanged.
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_rf_addr_r <= container_val_rf_addr_r;
                                        container_phase_r   <= CP_DICT_RD_VAL;
                                    end
                                end

                                CP_DICT_RD_VAL: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r + 64'd1);
                                            container_dmem_pending_r <= 1'b1;
                                            container_used_r       <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end else begin
                                            tos_r             <= tos_r - RF_AW'(3);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_STORE_DICT


                        // ===========================================================
                        // CONT_BUILD_TUPLE: like BUILD_LIST but no header slot.
                        // Handle = {size=count, addr=base}. Empty tuple still
                        // produces a handle with size 0 at the would-be base.
                        // ===========================================================
                        CONT_BUILD_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ((heap_ptr_r + cont_bt_alloc) > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else if (container_count_r == 7'd0) begin
                                        // Empty tuple: no dmem writes; commit handle.
                                        container_base_r       <= heap_ptr_r;
                                        container_wb_we_r      <= 1'b1;
                                        container_wb_addr_r    <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r    <= pycore_make_entry(
                                            PY_TAG_TUPLE,
                                            {64'd0, {32'b0, heap_ptr_r}});
                                        tos_r             <= tos_r + RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else begin
                                        container_base_r  <= heap_ptr_r;
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_idx_r   <= 7'd0;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                // RF addr settled; write element value.
                                CP_HDR: begin
                                    container_tag_r        <= cont_rf_rs1_tag;
                                    container_val_r        <= cont_rf_rs1_val;
                                    container_dmem_addr_r  <= pycore_tuple_val_addr(
                                        container_base_r, {25'b0, container_idx_r});
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    heap_ptr_r             <= heap_ptr_r + 32'd16;
                                    container_phase_r      <= CP_VAL;
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_tuple_tag_addr(
                                            container_base_r, {25'b0, container_idx_r});
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        heap_ptr_r             <= heap_ptr_r + 32'd16;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r     <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r}
                                                + 9'd1);
                                            container_phase_r   <= CP_HDR;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_TUPLE,
                                                {{57'b0, container_count_r},
                                                 {32'b0, container_base_r}});
                                            tos_r            <= tos_r
                                                - {2'b0, container_count_r} + 7'd1;
                                            fetch_skip_r     <= 1'b1;
                                            container_phase_r   <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_TUPLE

                        // ===========================================================
                        // CONT_SUBSCR_TUPLE: NB_SUBSCR on TUPLE handle.
                        // Like LIST subscript minus the header read; size is inline.
                        // Negative indices trap (unsigned bounds check) — see
                        // semantic deviations in bytecode_support.md.
                        // ===========================================================
                        CONT_SUBSCR_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_rs2_tag != PY_TAG_INT &&
                                                 cont_rs2_tag != PY_TAG_BOOL) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_key_u >= cont_tuple_size) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_base_r <= cont_rs1_addr;
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            cont_rs1_addr, cont_key_u[31:0]);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r       <= container_rd_data_r;
                                        container_dmem_addr_r <= container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r   <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r     <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_TUPLE

                        // =====================================================
                        // CONT_CONTAINS_LIST: CONTAINS_OP on LIST.
                        // rs1 = needle, rs2 = list. Linear scan; BOOL result.
                        // cur_arg_r[0]=1 inverts (not in).
                        // =====================================================
                        CONT_CONTAINS_LIST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs2_tag != PY_TAG_LIST) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_list_hdr_r <= container_rd_data_r;
                                        if (cont_hdr_len == 64'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]}); // empty: in→0, not in→1
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_list_obitem_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_obitem_buf;
                                        container_idx_r <= 7'd0;
                                        container_dmem_addr_r <= pycore_list_val_addr(
                                            cont_obitem_buf, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_contains_eq) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]}); // found: in→1, not in→0
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if ({25'b0, container_idx_r} + 32'd1
                                                     < cont_ext_hdr_len[31:0]) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_dmem_addr_r <= pycore_list_val_addr(
                                                container_buf_r,
                                                {25'b0, container_idx_r} + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]}); // miss: in→0, not in→1
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_LIST

                        // =====================================================
                        // CONT_CONTAINS_TUPLE: CONTAINS_OP on TUPLE (inline size).
                        // =====================================================
                        CONT_CONTAINS_TUPLE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs2_tag != PY_TAG_TUPLE) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (cont_tuple_size_rs2 == 64'd0) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                        container_wb_data_r <= pycore_make_entry(
                                            PY_TAG_BOOL,
                                            {{(PYCORE_VAL_WIDTH-1){1'b0}}, cur_arg_r[0]});
                                        tos_r             <= tos_r - RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end else begin
                                        container_src_buf_r <= cont_tuple_addr_rs2;
                                        container_src_len_r <= cont_tuple_size_rs2[31:0];
                                        container_idx_r     <= 7'd0;
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            cont_tuple_addr_rs2, 32'd0);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <=
                                            container_dmem_addr_r + 32'd16;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_contains_eq) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if ({25'b0, container_idx_r} + 32'd1
                                                     < container_src_len_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            container_dmem_addr_r <= pycore_tuple_val_addr(
                                                container_src_buf_r,
                                                {25'b0, container_idx_r} + 32'd1);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end else begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_TUPLE

                        // =====================================================
                        // CONT_CONTAINS_DICT: CONTAINS_OP on DICT.
                        // Probe like SUBSCR_DICT but miss → False (not MEM_FAULT).
                        // Needle/key = rs1; dict = rs2. Cross-tag numeric →
                        // DICT_COLLISION. Tombstones skipped.
                        // =====================================================
                        CONT_CONTAINS_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            // Empty → miss (False / True for not-in).
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                     cur_arg_r[0]});
                                                tos_r             <= tos_r - RF_AW'(1);
                                                fetch_skip_r      <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_wb_we_r   <= 1'b1;
                                                    container_wb_addr_r <=
                                                        RF_AW'(tos_r - RF_AW'(2));
                                                    container_wb_data_r <= pycore_make_entry(
                                                        PY_TAG_BOOL,
                                                        {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                         cur_arg_r[0]});
                                                    tos_r             <= tos_r - RF_AW'(1);
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_DICT

                        // =====================================================
                        // CONT_DELETE_DICT: DELETE_SUBSCR on DICT.
                        // rs1_r = key; rs2_r = dict. Same-tag hit → write
                        // TOMBSTONE to ktag, used--, pop 2. Cross-tag numeric →
                        // DICT_COLLISION. Miss → MEM_FAULT. Tombstones skipped.
                        // =====================================================
                        CONT_DELETE_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_finishing_r    <= 1'b0;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(2);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Tombstone the key tag; used-- via header.
                                            container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {124'b0, PY_TAG_TOMBSTONE};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KTAG;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_dict_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r - 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_used_r       <= container_used_r - 64'd1;
                                        container_finishing_r  <= 1'b1;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_DELETE_DICT


                        // ===========================================================
                        // CONT_BUILD_SET: allocate set (32B obj + contiguous table)
                        // + linear-probe insert all elements (rich_eq).
                        // ===========================================================
                        CONT_BUILD_SET: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ((heap_ptr_r + pycore_set_alloc_bytes(cont_set_min_slots))
                                            > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_slot_count_r <= cont_set_min_slots;
                                        container_used_r       <= 64'd0;
                                        container_probe_n_r    <= 32'd0;
                                        container_insert_new_r <= 1'b0;
                                        container_finishing_r  <= 1'b0;
                                        container_base_r       <= heap_ptr_r;
                                        container_buf_r        <= heap_ptr_r + 32'd32;
                                        heap_ptr_r             <= heap_ptr_r +
                                            pycore_set_alloc_bytes(cont_set_min_slots);
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_set_header(
                                            {32'b0, cont_set_min_slots}, 64'd0);
                                        container_dmem_pending_r <= 1'b1;
                                        // First element at tos-count.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(
                                                {2'b0, tos_r} - {2'b0, container_count_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_SET,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r <= tos_r - {2'b0, container_count_r}
                                                   + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_dmem_addr_r <=
                                                pycore_set_table_ptr_addr(container_base_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <=
                                                {{64{1'b0}}, {32'b0, container_buf_r}};
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_SET, {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_tag_r <= cont_rf_rs1_tag;
                                            container_val_r <= cont_rf_rs1_val;
                                            if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                                container_type_trap_r <= 1'b1;
                                            end else begin
                                                begin
                                                    logic [31:0] probe0;
                                                    probe0 = pycore_dict_key_hash(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val)
                                                        & (container_slot_count_r - 32'd1);
                                                    container_probe_r   <= probe0;
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, probe0);
                                                end
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_PROBE;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_set_val_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
                                                        container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Duplicate element — skip insert; advance.
                                            container_insert_new_r <= 1'b0;
                                            if (container_idx_r + 7'd1 < container_count_r) begin
                                                container_idx_r <= container_idx_r + 7'd1;
                                                container_rf_addr_r <= RF_AW'(
                                                    {2'b0, tos_r}
                                                    - {2'b0, container_count_r}
                                                    + {2'b0, container_idx_r} + 9'd1);
                                                container_phase_r <= CP_DICT_HASH;
                                            end else begin
                                                container_dmem_addr_r  <= container_base_r;
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= pycore_set_header(
                                                    {32'b0, container_slot_count_r},
                                                    container_used_r);
                                                container_dmem_pending_r <= 1'b1;
                                                container_finishing_r  <= 1'b1;
                                                container_phase_r <= CP_HDR;
                                            end
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_used_r <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                        end
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            container_idx_r <= container_idx_r + 7'd1;
                                            // NBA: idx still old → next elem at +1.
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r} + 9'd1);
                                            container_phase_r <= CP_DICT_HASH;
                                        end else begin
                                            // NBA: insert_new still old → include +1 if set.
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_set_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r +
                                                    (container_insert_new_r ? 64'd1 : 64'd0));
                                            container_dmem_pending_r <= 1'b1;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end
                                    end
                                end

                                // Next element: RF settled from prior rf_addr write.
                                CP_DICT_HASH: begin
                                    container_tag_r <= cont_rf_rs1_tag;
                                    container_val_r <= cont_rf_rs1_val;
                                    if (!pycore_dict_key_tag_ok(cont_rf_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        begin
                                            logic [31:0] probe0;
                                            probe0 = pycore_dict_key_hash(
                                                cont_rf_rs1_tag, cont_rf_rs1_val)
                                                & (container_slot_count_r - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, probe0);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_PROBE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_BUILD_SET


                        // ===========================================================
                        // CONT_SET_ADD: probe/insert element; grow → SET_GROW.
                        // rs1 = set handle (tos-1-arg); rs2 = element (tos-1).
                        // ===========================================================
                        CONT_SET_ADD: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_SET) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (!pycore_dict_key_tag_ok(cont_rs2_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs2_tag;
                                        container_val_r <= cont_rs2_val;
                                        container_insert_new_r  <= 1'b0;
                                        container_finishing_r   <= 1'b0;
                                        container_tomb_valid_r  <= 1'b0;
                                        container_tomb_idx_r    <= 32'd0;
                                        container_base_r         <= cont_rs1_addr;
                                        container_dmem_addr_r    <= cont_rs1_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_set_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_SET_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_SET_GROW;
                                                trap_marshal_entry_count_r <= 3'd2;
                                                trap_marshal_entries_r[0]  <= rs1_r;
                                                trap_marshal_entries_r[1]  <= rs2_r;
                                                container_phase_r          <= CP_DONE;
                                            end else begin
                                                container_set_grow_trap_r <= 1'b1;
                                            end
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_set_tag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            if (container_tomb_valid_r) begin
                                                if (cont_set_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_SET_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_SET_GROW;
                                                        trap_marshal_entry_count_r <= 3'd2;
                                                        trap_marshal_entries_r[0]  <= rs1_r;
                                                        trap_marshal_entries_r[1]  <= rs2_r;
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_set_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <=
                                                        container_tomb_idx_r;
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <=
                                                        pycore_set_val_addr(
                                                            container_buf_r,
                                                            container_tomb_idx_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <= container_val_r;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_WR_KVAL;
                                                end
                                            end else begin
                                                if (EXCORE_EN &&
                                                    pycore_trap_recoverable(
                                                        PY_TRAP_SET_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_SET_GROW;
                                                    trap_marshal_entry_count_r <= 3'd2;
                                                    trap_marshal_entries_r[0]  <= rs1_r;
                                                    trap_marshal_entries_r[1]  <= rs2_r;
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_set_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                if (cont_set_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_SET_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_SET_GROW;
                                                        trap_marshal_entry_count_r <= 3'd2;
                                                        trap_marshal_entries_r[0]  <= rs1_r;
                                                        trap_marshal_entries_r[1]  <= rs2_r;
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_set_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    begin
                                                        logic [31:0] ins;
                                                        ins = container_tomb_valid_r ?
                                                              container_tomb_idx_r :
                                                              container_probe_r;
                                                        container_probe_r      <= ins;
                                                        container_insert_new_r <= 1'b1;
                                                        container_dmem_addr_r  <=
                                                            pycore_set_val_addr(
                                                                container_buf_r, ins);
                                                        container_dmem_we_r    <= 1'b1;
                                                        container_dmem_wdata_r <=
                                                            container_val_r;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r <= CP_DICT_WR_KVAL;
                                                    end
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <=
                                                        container_probe_r;
                                                end
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_probe_n_r <=
                                                        container_slot_count_r;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
                                                        container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Already present — pop element only.
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_set_tag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= container_base_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_set_header(
                                            {32'b0, container_slot_count_r},
                                            container_used_r + 64'd1);
                                        container_dmem_pending_r <= 1'b1;
                                        container_used_r       <= container_used_r + 64'd1;
                                        container_finishing_r  <= 1'b1;
                                        container_phase_r <= CP_HDR;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SET_ADD


                        // ===========================================================
                        // CONT_CONTAINS_SET: CONTAINS_OP on SET (probe + rich_eq).
                        // ===========================================================
                        CONT_CONTAINS_SET: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_base_r         <= cont_rs2_addr;
                                        container_dmem_addr_r    <= cont_rs2_addr;
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_HDR;
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_set_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_set_tag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                container_wb_we_r   <= 1'b1;
                                                container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                                container_wb_data_r <= pycore_make_entry(
                                                    PY_TAG_BOOL,
                                                    {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                     cur_arg_r[0]});
                                                tos_r             <= tos_r - RF_AW'(1);
                                                fetch_skip_r      <= 1'b1;
                                                container_phase_r <= CP_DONE;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_wb_we_r   <= 1'b1;
                                                    container_wb_addr_r <=
                                                        RF_AW'(tos_r - RF_AW'(2));
                                                    container_wb_data_r <= pycore_make_entry(
                                                        PY_TAG_BOOL,
                                                        {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                         cur_arg_r[0]});
                                                    tos_r             <= tos_r - RF_AW'(1);
                                                    fetch_skip_r      <= 1'b1;
                                                    container_phase_r <= CP_DONE;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_set_tag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                container_probe_tag_r    <=
                                                    container_rd_data_r[3:0];
                                                container_dmem_addr_r    <=
                                                    pycore_set_val_addr(
                                                        container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 ~cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'(tos_r - RF_AW'(2));
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_BOOL,
                                                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                                                 cur_arg_r[0]});
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_set_tag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_CONTAINS_SET


                        // ===========================================================
                        // CONT_SET_UPDATE: always trap SET_UPDATE before commit.
                        // Entries: [set, iterable]; COMPLETED pop=1.
                        // ===========================================================
                        CONT_SET_UPDATE: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (cont_rs1_tag != PY_TAG_SET) begin
                                        container_type_trap_r <= 1'b1;
                                    end else if (EXCORE_EN &&
                                                 pycore_trap_recoverable(
                                                     PY_TRAP_SET_UPDATE)) begin
                                        trap_marshal_pending_r     <= 1'b1;
                                        trap_marshal_code_r        <= PY_TRAP_SET_UPDATE;
                                        trap_marshal_entry_count_r <= 3'd2;
                                        trap_marshal_entries_r[0]  <= rs1_r;
                                        trap_marshal_entries_r[1]  <= rs2_r;
                                        container_phase_r          <= CP_DONE;
                                    end else begin
                                        container_set_update_trap_r <= 1'b1;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SET_UPDATE


                        // ===========================================================
                        // CONT_LOAD_CONST: read co_consts[cur_arg_r] tuple element.
                        // Bounds check against tuple size (upper 64 bits of the
                        // consts_base_r handle value).
                        //   CP_INIT: bounds check; issue VAL read.
                        //   CP_VAL : save VAL; issue TAG read.
                        //   CP_TAG : assemble RF entry; wb at TOS; tos+=1.
                        // ===========================================================
                        CONT_LOAD_CONST: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ({32'b0, cur_arg_r} >= consts_base_r[127:64]) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            consts_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_VAL;
                                    end
                                end

                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            consts_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_TAG;
                                    end
                                end

                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r             <= tos_r + RF_AW'(1);
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LOAD_CONST

                        // ===========================================================
                        // CONT_LOAD_GLOBAL / LOAD_NAME:
                        //   Read co_names[namei] (VAL+TAG) → search key.
                        //   Linear-probe globals_base_r for that key.
                        //   Push value at TOS; if push_null, follow with a NULL
                        //   sentinel push (CP_LG_WB_NULL).
                        //   namei = LOAD_GLOBAL ? (arg >> 1) : arg (LOAD_NAME).
                        // ===========================================================
                        CONT_LOAD_GLOBAL: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    // namei: LOAD_GLOBAL uses arg>>1; LOAD_NAME
                                    // uses raw arg — the push_null flag was
                                    // sampled in S_EXEC and mirrors this shift.
                                    begin
                                        logic [31:0] namei;
                                        namei = container_push_null_r ?
                                                (cur_arg_r >> 1) : cur_arg_r;
                                        if ({32'b0, namei} >= names_base_r[127:64]) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_dmem_addr_r <= pycore_tuple_val_addr(
                                                names_base_r[31:0], namei);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            // Stash namei for CP_NAME_TAG.
                                            container_idx_r <= namei[6:0];
                                            container_phase_r <= CP_NAME_VAL;
                                        end
                                    end
                                end

                                CP_NAME_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            names_base_r[31:0], {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_TAG;
                                    end
                                end

                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Key ready in {container_rd_data_r[3:0],
                                        // container_val_r} — build search key
                                        // and start probing globals dict header.
                                        container_tag_r <= container_rd_data_r[3:0];
                                        // container_val_r already holds VAL.
                                        if (!pycore_dict_key_tag_ok(container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            container_base_r         <= globals_base_r;
                                            container_dmem_addr_r    <= globals_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_HDR;
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                        container_used_r       <= cont_dict_hdr_used;
                                        container_dmem_addr_r <=
                                            pycore_dict_table_ptr_addr(container_base_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r        <= CP_LIST_BUF;
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Name not found — NameError analog.
                                                container_mem_fault_r <= 1'b1;
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <= pycore_dict_vval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_RD_VVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_RD_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VTAG;
                                    end
                                end

                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        // Push value at TOS.
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r <= tos_r + RF_AW'(1);
                                        if (container_push_null_r) begin
                                            // Second beat: push NULL next cycle.
                                            container_phase_r <= CP_LG_WB_NULL;
                                        end else begin
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_LG_WB_NULL: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= pycore_make_entry(PY_TAG_NULL, '0);
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LOAD_GLOBAL

                        // ===========================================================
                        // CONT_STORE_NAME / STORE_GLOBAL:
                        //   Read co_names[cur_arg] key; set rf_addr to value at
                        //   RF[tos-1]; run STORE_DICT-style insert against
                        //   globals_base_r; tos -= 1.
                        //   All phases use container_base_r = globals_base_r.
                        // ===========================================================
                        CONT_STORE_NAME: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if ({32'b0, cur_arg_r} >= names_base_r[127:64]) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        container_dmem_addr_r <= pycore_tuple_val_addr(
                                            names_base_r[31:0], cur_arg_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_idx_r          <= cur_arg_r[6:0];
                                        container_phase_r        <= CP_NAME_VAL;
                                    end
                                end

                                CP_NAME_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_val_r <= container_rd_data_r;
                                        container_dmem_addr_r <= pycore_tuple_tag_addr(
                                            names_base_r[31:0], {25'b0, container_idx_r});
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_NAME_TAG;
                                    end
                                end

                                CP_NAME_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_tag_r <= container_rd_data_r[3:0];
                                        if (!pycore_dict_key_tag_ok(container_rd_data_r[3:0])) begin
                                            container_type_trap_r <= 1'b1;
                                        end else begin
                                            // Value @ RF[tos-1] — set RF addr early for
                                            // grow/collision marshal entry2.
                                            container_rf_addr_r      <= RF_AW'(tos_r - RF_AW'(1));
                                            container_val_rf_addr_r  <= RF_AW'(tos_r - RF_AW'(1));
                                            container_insert_new_r   <= 1'b0;
                                            container_finishing_r    <= 1'b0;
                                            container_tomb_valid_r   <= 1'b0;
                                            container_tomb_idx_r     <= 32'd0;
                                            container_base_r         <= globals_base_r;
                                            container_dmem_addr_r    <= globals_base_r;
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_HDR;
                                        end
                                    end
                                end

                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_finishing_r) begin
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            container_dmem_addr_r <=
                                                pycore_dict_table_ptr_addr(container_base_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_LIST_BUF;
                                        end
                                    end
                                end

                                CP_LIST_BUF: begin
                                    if (!container_dmem_pending_r) begin
                                        container_buf_r <= cont_dict_table_ptr;
                                        if ((container_slot_count_r == 32'd0) ||
                                            (cont_dict_table_ptr == 32'd0)) begin
                                            if (EXCORE_EN &&
                                                pycore_trap_recoverable(PY_TRAP_DICT_GROW)) begin
                                                trap_marshal_pending_r     <= 1'b1;
                                                trap_marshal_code_r        <= PY_TRAP_DICT_GROW;
                                                trap_marshal_entry_count_r <= 3'd3;
                                                trap_marshal_entries_r[0]  <=
                                                    pycore_make_entry(
                                                        PY_TAG_DICT,
                                                        {{96{1'b0}}, container_base_r});
                                                trap_marshal_entries_r[1]  <=
                                                    pycore_make_entry(
                                                        container_tag_r, container_val_r);
                                                trap_marshal_entries_r[2]  <=
                                                    pycore_make_entry(
                                                        cont_rf_rs1_tag, cont_rf_rs1_val);
                                                container_phase_r          <= CP_DONE;
                                            end else begin
                                                container_dict_grow_trap_r <= 1'b1;
                                            end
                                        end else begin
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (container_slot_count_r - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <=
                                                    pycore_dict_ktag_addr(
                                                        cont_dict_table_ptr, probe0);
                                            end
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            if (container_tomb_valid_r) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <=
                                                            pycore_make_entry(
                                                                PY_TAG_DICT,
                                                                {{96{1'b0}},
                                                                 container_base_r});
                                                        trap_marshal_entries_r[1]  <=
                                                            pycore_make_entry(
                                                                container_tag_r,
                                                                container_val_r);
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    container_probe_r      <=
                                                        container_tomb_idx_r;
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <=
                                                        pycore_dict_kval_addr(
                                                            container_buf_r,
                                                            container_tomb_idx_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <= container_val_r;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_WR_KVAL;
                                                end
                                            end else begin
                                                if (EXCORE_EN &&
                                                    pycore_trap_recoverable(
                                                        PY_TRAP_DICT_GROW)) begin
                                                    trap_marshal_pending_r     <= 1'b1;
                                                    trap_marshal_code_r        <=
                                                        PY_TRAP_DICT_GROW;
                                                    trap_marshal_entry_count_r <= 3'd3;
                                                    trap_marshal_entries_r[0]  <=
                                                        pycore_make_entry(
                                                            PY_TAG_DICT,
                                                            {{96{1'b0}}, container_base_r});
                                                    trap_marshal_entries_r[1]  <=
                                                        pycore_make_entry(
                                                            container_tag_r, container_val_r);
                                                    trap_marshal_entries_r[2]  <=
                                                        pycore_make_entry(
                                                            cont_rf_rs1_tag, cont_rf_rs1_val);
                                                    container_phase_r          <= CP_DONE;
                                                end else begin
                                                    container_dict_grow_trap_r <= 1'b1;
                                                end
                                            end
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                if (cont_dict_needs_grow) begin
                                                    if (EXCORE_EN &&
                                                        pycore_trap_recoverable(
                                                            PY_TRAP_DICT_GROW)) begin
                                                        trap_marshal_pending_r     <= 1'b1;
                                                        trap_marshal_code_r        <=
                                                            PY_TRAP_DICT_GROW;
                                                        trap_marshal_entry_count_r <= 3'd3;
                                                        trap_marshal_entries_r[0]  <=
                                                            pycore_make_entry(
                                                                PY_TAG_DICT,
                                                                {{96{1'b0}},
                                                                 container_base_r});
                                                        trap_marshal_entries_r[1]  <=
                                                            pycore_make_entry(
                                                                container_tag_r,
                                                                container_val_r);
                                                        trap_marshal_entries_r[2]  <=
                                                            pycore_make_entry(
                                                                cont_rf_rs1_tag,
                                                                cont_rf_rs1_val);
                                                        container_phase_r          <= CP_DONE;
                                                    end else begin
                                                        container_dict_grow_trap_r <= 1'b1;
                                                    end
                                                end else begin
                                                    begin
                                                        logic [31:0] ins;
                                                        ins = container_tomb_valid_r ?
                                                              container_tomb_idx_r :
                                                              container_probe_r;
                                                        container_probe_r      <= ins;
                                                        container_insert_new_r <= 1'b1;
                                                        container_dmem_addr_r  <=
                                                            pycore_dict_kval_addr(
                                                                container_buf_r, ins);
                                                        container_dmem_we_r    <= 1'b1;
                                                        container_dmem_wdata_r <=
                                                            container_val_r;
                                                        container_dmem_pending_r <= 1'b1;
                                                        container_phase_r <= CP_DICT_WR_KVAL;
                                                    end
                                                end
                                            end else if (pycore_dict_tombstone(
                                                            container_rd_data_r[3:0])) begin
                                                if (!container_tomb_valid_r) begin
                                                    container_tomb_valid_r <= 1'b1;
                                                    container_tomb_idx_r   <=
                                                        container_probe_r;
                                                end
                                                if (container_probe_n_r + 32'd1
                                                        >= container_slot_count_r) begin
                                                    container_probe_n_r <=
                                                        container_slot_count_r;
                                                end else begin
                                                    container_probe_r <= cont_probe_next;
                                                    container_dmem_addr_r <=
                                                        pycore_dict_ktag_addr(
                                                            container_buf_r, cont_probe_next);
                                                    container_dmem_we_r      <= 1'b0;
                                                    container_dmem_pending_r <= 1'b1;
                                                end
                                            end else begin
                                                // Occupied: rich_eq (incl. cross-tag numeric) at CHK_VAL.
                                                container_probe_tag_r    <= container_rd_data_r[3:0];
                                                container_dmem_addr_r    <= pycore_dict_kval_addr(
                                                    container_buf_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r        <= CP_DICT_CHK_VAL;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                container_buf_r, container_probe_r);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= container_val_r;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_WR_KVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_buf_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_KTAG;
                                    end
                                end

                                CP_DICT_WR_KTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_rf_addr_r <= container_val_rf_addr_r;
                                        container_phase_r   <= CP_DICT_RD_VAL;
                                    end
                                end

                                CP_DICT_RD_VAL: begin
                                    container_dmem_addr_r  <= pycore_dict_vval_addr(
                                        container_buf_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_lfb_lo_r <= cont_rf_rs1_tag;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_buf_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_lfb_lo_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            container_dmem_addr_r  <= container_base_r;
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= pycore_dict_header(
                                                {32'b0, container_slot_count_r},
                                                container_used_r + 64'd1);
                                            container_dmem_pending_r <= 1'b1;
                                            container_used_r       <= container_used_r + 64'd1;
                                            container_insert_new_r <= 1'b0;
                                            container_finishing_r  <= 1'b1;
                                            container_phase_r <= CP_HDR;
                                        end else begin
                                            tos_r             <= tos_r - RF_AW'(1);
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_STORE_NAME

                        // ===========================================================
                        // CONT_LFB_PAIR: two-beat LOAD_FAST_BORROW.  arg[7:4] is
                        // pushed first, then arg[3:0] — both as reads relative to
                        // cur_locals_base_r.  Uses container_lfb_hi_r/lo_r
                        // sampled at S_EXEC init.
                        // ===========================================================
                        CONT_LFB_PAIR: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} + {5'b0, container_lfb_hi_r});
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} + {5'b0, container_lfb_lo_r});
                                    container_phase_r <= CP_LFB_SECOND;
                                end

                                CP_LFB_SECOND: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LFB_PAIR

                        // ===========================================================
                        // CONT_SWAP: two-beat RF exchange.  rs1_r = TOS and
                        // rs2_r = stack[-oparg] were latched in S_DECODE.
                        // Beat1 writes deep→TOS; beat2 writes TOS→deep.
                        // Net stack effect 0 (do not touch tos_r).
                        // ===========================================================
                        CONT_SWAP: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - 9'd1);
                                    container_wb_data_r <= rs2_r;
                                    container_phase_r   <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - {2'b0, cur_arg_r[6:0]});
                                    container_wb_data_r <= rs1_r;
                                    fetch_skip_r        <= 1'b1;
                                    container_phase_r   <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SWAP

                        // ===========================================================
                        // CONT_SFLF: STORE_FAST_LOAD_FAST.  rs1_r = TOS latched
                        // at decode.  Beat1 stores TOS → locals[hi] and pops;
                        // beat2 pushes locals[lo].  Net stack 0.  hi==lo is
                        // safe: the store completes before the reload read.
                        // ===========================================================
                        CONT_SFLF: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_hi_r});
                                    container_wb_data_r <= rs1_r;
                                    tos_r <= tos_r - RF_AW'(1);
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_lo_r});
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    // hi==lo: RF write from CP_INIT is not yet
                                    // visible on rf_rs1; bypass the stored TOS.
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <=
                                        (container_lfb_hi_r == container_lfb_lo_r)
                                            ? rs1_r : rf_rs1;
                                    tos_r <= tos_r + RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SFLF

                        // ===========================================================
                        // CONT_SFSF: STORE_FAST_STORE_FAST.  rs1_r = TOS.  Beat1
                        // stores TOS → locals[hi] and pops; beat2 stores the new
                        // TOS → locals[lo] and pops.  Net stack −2.  Pop order
                        // matches CPython: hi first from TOS, then lo.
                        // ===========================================================
                        CONT_SFSF: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_hi_r});
                                    container_wb_data_r <= rs1_r;
                                    // Point rs1 at the second-from-top (old
                                    // tos_r-2) for the next-cycle store.
                                    container_rf_addr_r <= RF_AW'(
                                        {2'b0, tos_r} - 9'd2);
                                    tos_r <= tos_r - RF_AW'(1);
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, container_lfb_lo_r});
                                    container_wb_data_r <= rf_rs1;
                                    tos_r <= tos_r - RF_AW'(1);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SFSF

                        // ===========================================================
                        // CONT_LFAC: LOAD_FAST_AND_CLEAR.  rs1_r = latched local
                        // value from S_DECODE.  Beat1 pushes it to TOS; beat2
                        // writes UNINIT into locals[oparg].  Net stack +1.
                        // Unbound slots do not trap (unlike DELETE_FAST).
                        // ===========================================================
                        CONT_LFAC: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                    container_wb_data_r <= rs1_r;
                                    tos_r <= tos_r + RF_AW'(1);
                                    container_phase_r <= CP_LFB_FIRST;
                                end

                                CP_LFB_FIRST: begin
                                    container_wb_we_r   <= 1'b1;
                                    container_wb_addr_r <= RF_AW'(
                                        {2'b0, cur_locals_base_r} +
                                        {5'b0, cur_arg_r[7:0]});
                                    container_wb_data_r <=
                                        pycore_make_entry(PY_TAG_UNINIT, '0);
                                    fetch_skip_r      <= 1'b1;
                                    container_phase_r <= CP_DONE;
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_LFAC


                        default: ;

                    endcase
                end // S_CONTAINER

                // ----------------------------------------------------------
                // S_BOOT: image-boot reset walker.  Runs once at cold start
                // when BOOT_EN=1.  Sequence:
                //
                //   Phase 0 : issue boot record pair0 VAL read.
                //   Phase 1 : latch code_obj addr; issue pair0 TAG read.
                //   Phase 2 : verify tag == CODE_OBJECT; issue pair1 VAL.
                //   Phase 3 : latch globals dict addr; issue pair1 TAG.
                //   Phase 4 : verify tag == DICT; latch globals_base_r,
                //             cur_code_r.  Issue code field 0 (entry_slot).
                //   Phase 5 : latch entry_slot; issue field 1 (co_consts).
                //   Phase 6 : latch consts_base_r; issue field 2 (co_names).
                //   Phase 7 : latch names_base_r; issue field 3 (metadata).
                //             (Metadata read discarded — module argcount=0.)
                //   Phase 8 : redirect fetch to entry_slot; go DONE.
                //   Phase 15: terminal marker → S_FETCH.
                //
                // Boot record layout (see pycore_defs.svh):
                //   PYCORE_BOOT_RECORD_ADDR + 0  : module code object VAL
                //   PYCORE_BOOT_RECORD_ADDR + 16 : module code object TAG
                //   PYCORE_BOOT_RECORD_ADDR + 32 : globals dict VAL
                //   PYCORE_BOOT_RECORD_ADDR + 48 : globals dict TAG
                // ----------------------------------------------------------
                S_BOOT: begin
                    if (container_dmem_pending_r && dmem_ack_i) begin
                        container_dmem_pending_r <= 1'b0;
                        container_rd_data_r      <= dmem_rdata_i;
                    end

                    unique case (boot_phase_r)

                        4'd0: begin
                            container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR;
                            container_dmem_we_r      <= 1'b0;
                            container_dmem_pending_r <= 1'b1;
                            boot_phase_r             <= 4'd1;
                        end

                        4'd1: begin
                            if (!container_dmem_pending_r) begin
                                cur_code_r <= container_rd_data_r[31:0];
                                container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR + 32'd16;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd2;
                            end
                        end

                        4'd2: begin
                            if (!container_dmem_pending_r) begin
                                if (container_rd_data_r[3:0] != PY_TAG_CODE_OBJECT) begin
                                    container_mem_fault_r <= 1'b1;
                                end else begin
                                    container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR + 32'd32;
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    boot_phase_r             <= 4'd3;
                                end
                            end
                        end

                        4'd3: begin
                            if (!container_dmem_pending_r) begin
                                globals_base_r <= container_rd_data_r[31:0];
                                container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR + 32'd48;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd4;
                            end
                        end

                        4'd4: begin
                            if (!container_dmem_pending_r) begin
                                if (container_rd_data_r[3:0] != PY_TAG_DICT) begin
                                    container_mem_fault_r <= 1'b1;
                                end else begin
                                    // Kick code field 0 (entry_slot VAL).
                                    container_dmem_addr_r    <= pycore_code_field_val_addr(
                                        cur_code_r, PYCORE_CODE_FIELD_ENTRY_SLOT);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    boot_phase_r             <= 4'd5;
                                end
                            end
                        end

                        4'd5: begin
                            if (!container_dmem_pending_r) begin
                                call_entry_slot_r <= container_rd_data_r[63:0];
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd6;
                            end
                        end

                        4'd6: begin
                            if (!container_dmem_pending_r) begin
                                consts_base_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd7;
                            end
                        end

                        4'd7: begin
                            if (!container_dmem_pending_r) begin
                                names_base_r <= container_rd_data_r;
                                // Skip metadata read for the module frame —
                                // module code always has argcount=0.
                                boot_phase_r <= 4'd8;
                            end
                        end

                        4'd8: begin
                            redirect_pending_r <= 1'b1;
                            redirect_tgt_r     <= call_entry_slot_r[31:0];
                            boot_phase_r       <= BOOT_PHASE_DONE;
                        end

                        default: ;
                    endcase
                end

                // ----------------------------------------------------------
                // S_TRAP_MARSHAL: assert trap_req_valid_o (combinational,
                // see below) with the operands trap_marshal_* already
                // latched by the container op that detected the recoverable
                // trap. No dmem or RF activity here — pycore is "frozen"
                // per the memory-ownership protocol until trap_res arrives.
                S_TRAP_MARSHAL: begin
                    if (trap_req_ready_i) begin
                        trap_marshal_pending_r <= 1'b0;
                        trap_res_seen_r        <= 1'b0;
                        trap_wait_push_idx_r   <= '0;
                        // state_next = S_TRAP_WAIT (from always_comb)
                    end
                end

                // ----------------------------------------------------------
                // S_TRAP_WAIT: apply the excore's result once trap_res_valid_i
                // arrives — heap_ptr adoption, pop, then push_count RF writes
                // (one per cycle; the RF write port is single-slot) — then
                // resume / retry / forward-fatal per trap_res_code_i.
                S_TRAP_WAIT: begin
                    if (trap_res_valid_i && !trap_res_seen_r) begin
                        // First cycle observing the result: latch it and
                        // apply heap_ptr + pop right away.
                        heap_ptr_r          <= trap_res_heap_ptr_i;
                        tos_r               <= tos_r - RF_AW'({5'b0, trap_res_pop_count_i});
                        trap_res_code_r2    <= trap_res_code_i;
                        trap_res_fatal_r2   <= trap_res_fatal_code_i;
                        trap_res_push_r     <= trap_res_push_count_i;
                        trap_res_entries_r2 <= trap_res_entries_i;
                        trap_res_seen_r     <= 1'b1;
                        trap_wait_push_idx_r <= 2'd0;
                    end else if (trap_res_seen_r &&
                                 (trap_wait_push_idx_r < {1'b0, trap_res_push_r})) begin
                        // Sequence one push write per cycle at the (already
                        // post-pop) tos.
                        container_wb_we_r   <= 1'b1;
                        container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                        container_wb_data_r <= trap_res_entries_r2[trap_wait_push_idx_r];
                        tos_r                <= tos_r + RF_AW'(1);
                        trap_wait_push_idx_r <= trap_wait_push_idx_r + 2'd1;
                    end else if (trap_res_seen_r) begin
                        // All pushes done: resume / retry / forward-fatal.
                        trap_res_seen_r <= 1'b0;
                        unique case (trap_res_code_r2)
                            TRAP_RES_COMPLETED: begin
                                fetch_skip_r <= 1'b1; // resume at next instr
                            end
                            TRAP_RES_RETRY: begin
                                redirect_pending_r <= 1'b1;
                                redirect_tgt_r     <= cur_pc_r; // re-dispatch same pc
                            end
                            default: begin // TRAP_RES_FATAL
                                excore_fatal_trap_r <= 1'b1;
                                excore_fatal_code_r <= trap_res_fatal_r2;
                            end
                        endcase
                    end
                end

                // ----------------------------------------------------------
                S_HALT: ;  // state_next = S_HALT (from always_comb)

                default: ;  // state_next = S_FETCH (from always_comb)

            endcase
        end
    end

endmodule
