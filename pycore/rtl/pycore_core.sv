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
    parameter int STRING_MEM_BYTES = 65536,
    parameter int STRING_MAX_LEN = 4096,
    parameter longint unsigned STRING_RUNTIME_BASE = 64'd16384,
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
    // Test-only trigger for the §6.1 container↔CALL spike.  When enabled,
    // CONT_GET_ITER may launch a CALL from a synthetic CALL-ready stack.
    // Production object-iterator launch sites are added in §10 step 6.
    parameter bit CONTAINER_CALL_SPIKE_EN = 1'b0,
    // EXCORE_EN = 1 : a recoverable trap (pycore_trap_recoverable(code))
    //                 enters S_TRAP_MARSHAL / S_TRAP_WAIT instead of
    //                 halting -- see pycore_excore_system.sv (Phase C).
    // EXCORE_EN = 0 : default.  Every legacy unit tb instantiates
    //                 pycore_core (via pycore_system) without overriding
    //                 this, so trap behavior is byte-identical to Phase A.
    parameter bit EXCORE_EN = 1'b0,
    parameter int MAX_TRAP_ENTRIES = 4,
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
    output logic [4:0]                    trap_req_code_o,
    output logic [31:0]                   trap_req_pc_o,
    output logic [39:0]                   trap_req_instr_o,
    output logic [31:0]                   trap_req_heap_ptr_o,
    output logic [2:0]                    trap_req_entry_count_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] trap_req_entries_o [0:MAX_TRAP_ENTRIES-1],
    // trap_res (excore -> pycore, via trap_mailbox.sv).
    input  logic                          trap_res_valid_i,
    output logic                          trap_res_ready_o,
    input  logic [3:0]                    trap_res_code_i,
    input  logic [4:0]                    trap_res_fatal_code_i,
    input  logic [2:0]                    trap_res_pop_count_i,
    input  logic [1:0]                    trap_res_push_count_i,
    input  logic [31:0]                   trap_res_heap_ptr_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] trap_res_entries_i [0:MAX_RES_ENTRIES-1],
    // status
    output logic                          trap_out_o,
    output logic [4:0]                    trap_code_o,
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

    `include "pycore_cont_defs.svh"

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
    logic [31:0]                   builtins_base_r;

    // One-cycle RF write issued from S_RETURN to deposit the callee's return
    // value (or saved instance under ret_discard_push_self) at tos_base.
    logic             return_wb_we_r;
    logic [RF_AW-1:0] return_wb_addr_r;

    // Fetch handshake bookkeeping.
    logic                          fetch_skip_r;
    logic                          redirect_pending_r;
    logic [31:0]                   redirect_tgt_r;

    // S_CALL / S_RETURN management (multi-phase FSM with code-object reads).
    logic                          call_sent_r;   // call_valid was pulsed
    logic                          frame_dmem_pending_r; // frame push or pop in flight
    logic [4:0]                    call_phase_r;
    logic [2:0]                    return_phase_r;
    // CALL / CALL_KW / CALL_FUNCTION_EX mode (see CALL_MODE_* localparams).
    logic [1:0]                    call_mode_r;
    logic [7:0]                    call_n_pos_r;
    logic [7:0]                    call_n_kwargs_r;
    // Latched CALL_KW stack bases (set once in binder sub 34).  Must not track
    // call_argcount_r: *args packing bumps argc and would move scratch.
    logic [15:0]                   call_kw_val_base_r;     // incoming kwargs[i]
    logic [15:0]                   call_kw_scratch_base_r; // parked kwargs[i]
    logic [127:0]                  call_kw_names_r;    // names TUPLE or kwargs DICT
    logic [127:0]                  call_varnames_r;    // callee co_varnames TUPLE
    logic [127:0]                  call_kwdefaults_r;  // callee co_kwdefaults DICT
    logic [15:0]                   call_kwonly_r;
    logic [15:0]                   call_total_params_r;
    logic                          call_varargs_r;     // callee CO_VARARGS flag
    logic                          call_varkw_r;       // callee CO_VARKEYWORDS
    logic [15:0]                   call_posonly_r;     // co_posonlyargcount
    // **kwargs dict under construction: {slot_count[31:0], obj_addr[31:0]}.
    // Order buffer and hash table follow the object contiguously, so both
    // pointers are derived (cont_varkw_order_ptr / cont_varkw_table_ptr).
    logic [127:0]                  call_varkw_dict_r;
    // Bitmask of caller keyword indices that matched no formal parameter and
    // therefore belong in **kwargs (CALL_KW: names-tuple index; EX_KW: kwargs
    // dict order-sidecar index).
    logic [127:0]                  call_varkw_left_r;
    logic [4:0]                    call_varkw_step_r;  // nested step, subs 52-55
    logic                          call_varkw_alloced_r;
    logic [5:0]                    call_after_varargs_sub_r;
    logic                          call_varargs_to_frame_r;
    logic                          call_args_is_list_r; // EX expand source tag
    // Boot phase counter — reset walker for S_BOOT.
    logic [3:0]                    boot_phase_r;
    // Scratchpad regs latched during S_CALL / S_RETURN for a pending
    // frame transition.  Preserved across the code-object reads so the
    // frame push finally uses the callee's freshly-read fields.
    logic [31:0]                   call_code_addr_r;   // callee code byte addr
    logic [63:0]                   call_entry_slot_r;  // entry slot index
    logic [127:0]                  call_consts_r;      // callee co_consts TUPLE
    logic [127:0]                  call_names_r;       // callee co_names TUPLE
    logic [15:0]                   call_argcount_r;    // effective/supplied argc
    logic [15:0]                   call_meta_argc_r;   // co_argcount from metadata
    logic [15:0]                   call_nlocals_r;     // callee metadata nlocals
    logic [RF_AW-1:0]              call_new_locals_r;  // locals base (self or arg0)
    logic [RF_AW-1:0]              call_tos_base_r;    // tos - oparg - 2 (callable)
    // OBJECT callable address (BOUND_METHOD / TYPE); code addr for CODE_OBJECT.
    logic [31:0]                   call_obj_addr_r;
    // co_defaults TUPLE handle {size[63:0], addr[63:0]}.
    logic [127:0]                  call_defaults_r;
    logic [15:0]                   call_defaults_len_r;
    logic [15:0]                   call_min_argc_r;
    // Defaults-fill / TYPE-setup sub-phase (used under call_phase 8–14).
    logic [5:0]                    call_sub_r;
    // Self entry while unwrapping BOUND_METHOD / installing TYPE instance.
    logic [3:0]                    call_self_tag_r;
    logic [127:0]                  call_self_val_r;
    logic [127:0]                  call_range_start_r;
    logic [127:0]                  call_range_stop_r;
    logic [127:0]                  call_range_step_r;
    // Instance byte address for TYPE instantiation / ret_discard_push_self.
    logic [31:0]                   call_inst_addr_r;
    // Mode installed for the frame being pushed (1 ⇒ discard return, push self).
    logic                          call_ret_mode_r;
    logic [63:0]                   call_saved_inst_r;
    // Live / latched ret-mode for S_RETURN writeback (from frame pop).
    logic                          frame_ret_mode_r;
    logic [63:0]                   frame_saved_inst_r;
    // One-cycle pulse: raise PY_TRAP_CALL_FILTER for callable checks and
    // frame_fault so the trap block sees a proper CALL_FILTER code rather
    // than being multiplexed through ILLEGAL_OPCODE.
    logic                          call_filter_trap_r;
    // One-cycle pulse: __init__ returned a non-NONE value.
    logic                          return_type_trap_r;
    // RETURN writeback data (normal rs1, or saved instance under ret_discard).
    logic [PYCORE_ENTRY_WIDTH-1:0] return_wb_data_r;

    // -----------------------------------------------------------------------
    // S_CONTAINER state — heap allocator and container operation registers.
    // -----------------------------------------------------------------------
    // Heap bump allocator.  Starts at PYCORE_HEAP_BASE and grows upward.
    // OOM is detected before each allocation; traps PY_TRAP_MEM_FAULT.
    logic [31:0]                   heap_ptr_r;

    // Which container operation is in flight (CONT_* constants above).
    logic [5:0]                    container_op_r;
    // Which phase within the current operation (CP_* constants above).
    logic [5:0]                    container_phase_r;
    // Container↔CALL pause/resume contract (§6.1).  A container arm first
    // arranges a normal CALL-ready RF stack, advances to a wait phase, and
    // pulses container_call_pending_r.  The core snapshots the instruction
    // context, runs S_CALL/S_RETURN unchanged, then re-enters S_CONTAINER with
    // container_call_return_valid_r/result_r set.  CALL scratch may overwrite
    // other container_* registers; iterator identity is preserved in saved_rs1.
    logic                          container_call_pending_r;
    logic                          container_call_active_r;
    logic                          container_call_returning_r;
    logic                          container_call_return_valid_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] container_call_result_r;
    logic [5:0]                    container_call_saved_op_r;
    logic [5:0]                    container_call_saved_phase_r;
    logic [7:0]                    container_call_saved_opcode_r;
    logic [31:0]                   container_call_saved_arg_r;
    logic [31:0]                   container_call_saved_pc_r;
    logic [RF_AW-1:0]              container_call_saved_tos_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] container_call_saved_rs1_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] container_call_saved_rs2_r;
    // §6.1.1: protocol-launched CALL raised; resume paused container with
    // call_exc_* instead of return_valid.  Exc unwind reuses S_RETURN pop.
    logic                          call_exc_pending_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] call_exc_handle_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] call_exc_type_r;
    logic                          container_call_exc_unwind_r;
    // Borrow CONT_LOAD_ATTR to resolve __iter__/__next__; remember home op.
    logic                          container_proto_resolve_r;
    logic [5:0]                    container_proto_op_r;
    // FOR_ITER HEAP_ITER: ITER hybrid preserved while rs1 holds the OBJECT
    // receiver for ATTR / method-self staging.
    logic [PYCORE_ENTRY_WIDTH-1:0] container_proto_iter_r;
    // Raising type entry stashed at CONT_RAISE entry (before OBK_EXCEPTION).
    logic [PYCORE_ENTRY_WIDTH-1:0] raise_type_entry_r;
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
    logic [127:0]                  container_range_start_r;
    logic [127:0]                  container_range_stop_r;
    logic [127:0]                  container_range_step_r;
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
    // DICT v3 insertion-order sidecar state.
    logic [31:0]                   container_order_ptr_r;
    logic [63:0]                   container_order_len_r;
    logic [63:0]                   container_dict_version_r;
    logic [31:0]                   container_order_idx_r;
    logic [3:0]                    container_order_key_tag_r;
    logic [127:0]                  container_order_shift_val_r;
    logic [3:0]                    container_order_shift_tag_r;
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
    logic                          container_src_is_tuple_r;
    // UNPACK_EX: oparg = before | (after << 8).  The mode register selects
    // after-element pushes, starred-list copy, then before-element pushes.
    logic [7:0]                    container_unpack_before_r;
    logic [7:0]                    container_unpack_after_r;
    logic [1:0]                    container_unpack_mode_r;
    // One-cycle pulse: CONT_LIST_EXTEND non-empty source (always excore).
    logic                          container_list_extend_trap_r;
    // One-cycle pulse: CONT_DELETE_LIST needs an element shift (excore).
    logic                          container_list_delete_trap_r;
    // One-cycle pulses: dict/set grow (fatal when EXCORE_EN=0; otherwise
    // marshaled like LIST_GROW before any commit).
    logic                          container_dict_grow_trap_r;
    logic                          container_set_grow_trap_r;
    logic                          container_set_update_trap_r;
    // Occupied probe slot tag latched at CP_DICT_PROBE for rich_eq at CHK_VAL.
    logic [3:0]                    container_probe_tag_r;
    // STORE_DICT / STORE_NAME / SET_ADD: first tombstone index seen during
    // probe (insert target when the key/element is absent).
    logic                          container_tomb_valid_r;
    logic [31:0]                   container_tomb_idx_r;
    // Contamination tracking: set while building/bulk-inserting when an
    // OBJECT key/element is committed; folded into the final MUT_COLLEC handle
    // (value[123]) and written back to the container's RF slot.
    logic                          container_contam_r;
    // Bulk DICT_UPDATE / SET_UPDATE (contaminated pycore path): source table
    // base, source slot count and current walk index, plus the destination
    // handle RF slot to rewrite when the op finishes.
    logic [31:0]                   container_src_base_r;
    logic [31:0]                   container_src_slots_r;
    logic [31:0]                   container_src_idx_r;
    logic [8:0]                    container_dst_rf_addr_r;
    // Bulk pycore rehash bookkeeping (SET_UPDATE / DICT_UPDATE / DICT_MERGE):
    //   old_table/old_slots : the destination's PRE-resize hash table, walked
    //     during rehash while container_buf_r/container_slot_count_r name the
    //     freshly allocated target table.
    //   bulk_mode           : REHASH (relocating the destination) vs INSERT
    //     (folding source elements in) — selects the post-insert continuation.
    //   src_kind            : which source collection layout to walk.
    //   bulk_size           : source element count (used for the resize check).
    //   old_order           : DICT rehash carries the source order buffer base
    //     across the order-copy + table-rehash passes.
    logic [31:0]                   container_old_table_r;
    logic [31:0]                   container_old_slots_r;
    logic [1:0]                    container_bulk_mode_r;
    logic [2:0]                    container_src_kind_r;
    logic [63:0]                   container_bulk_size_r;
    logic [31:0]                   container_old_order_r;

    // -----------------------------------------------------------------------
    // S_TRAP_MARSHAL / S_TRAP_WAIT (Phase C) registers.
    // -----------------------------------------------------------------------
    // Set (alongside container_phase_r <= CP_DONE) by a container op that
    // detects a recoverable trap under EXCORE_EN=1, instead of raising the
    // fatal one-cycle pulse (e.g. container_list_grow_trap_r). Selects
    // S_TRAP_MARSHAL over S_FETCH as the CP_DONE exit target; cleared on
    // entry to S_TRAP_MARSHAL.
    logic                          trap_marshal_pending_r;
    logic [4:0]                    trap_marshal_code_r;
    logic [2:0]                    trap_marshal_entry_count_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_marshal_entries_r [0:3]; // MAX_TRAP_ENTRIES
    // S_TRAP_WAIT: sequences push_count_i RF writes (one per cycle) after
    // popping pop_count_i, before applying COMPLETED/RETRY/FATAL.
    logic [1:0]                    trap_wait_push_idx_r;
    // 1 once the result fields below have been latched from trap_res_*_i
    // (the first cycle trap_res_valid_i is seen); cleared once the
    // resume/retry/fatal decision has been applied.
    logic                          trap_res_seen_r;
    logic [3:0]                    trap_res_code_r2;
    logic [4:0]                    trap_res_fatal_r2;
    logic [1:0]                    trap_res_push_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] trap_res_entries_r2 [0:1]; // MAX_RES_ENTRIES
    // One-cycle pulse: forward an excore-reported FATAL code into
    // pycore_trap as a normal halt.
    logic                          excore_fatal_trap_r;
    logic [4:0]                    excore_fatal_code_r;

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
    logic                          container_raise_trap_r;
    // Active exception (§7.6) + boot StopIteration latch (§7.4).
    logic [PYCORE_ENTRY_WIDTH-1:0] active_exc_r;
    logic                          active_exc_valid_r;
    logic [PYCORE_ENTRY_WIDTH-1:0] iter_exhaust_type_r;
    // One-cycle pulse: LOAD/DELETE_ATTR miss after __dict__ + MRO → ATTR_ERROR.
    logic                          container_attr_error_r;

    // One-cycle pulse outputs to frame manager (registered).
    logic                          frame_call_valid_r;
    logic                          frame_return_valid_r;

    // locals_base tracked by the frame module (drives decode).
    logic [RF_AW-1:0]              cur_locals_base_r;

    // One-cycle RF control pulses for frame transitions.
    logic                          rf_set_locals_r;
    logic [RF_AW-1:0]              rf_new_locals_r;
    logic                          rf_init_frame_r;
    logic [RF_AW-1:0]              rf_init_from_r;
    logic [RF_AW-1:0]              rf_init_until_r;

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
    logic        binary_list_iadd;
    logic        route_container;
    logic [2:0]  dec_mem_op;
    logic        dec_illegal;

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
        .push_stack_o(),
        .pop_stack_o(),
        .mem_op_o(dec_mem_op),
        .illegal_opcode_o(dec_illegal),
        .decoded_pc_o()
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
            // / SWAP / paired-FAST ops / LOAD_FAST_AND_CLEAR / TO_BOOL /
            // CALL_INTRINSIC_1 / UNPACK_EX are container ops (S_CONTAINER
            // manages tos and RF writes).
            PY_OP_LOAD_CONST, PY_OP_LOAD_GLOBAL, PY_OP_LOAD_NAME,
            PY_OP_STORE_NAME, PY_OP_STORE_GLOBAL,
            PY_OP_LOAD_ATTR, PY_OP_STORE_ATTR, PY_OP_DELETE_ATTR,
            PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW,
            PY_OP_LOAD_FAST_LOAD_FAST,
            PY_OP_LOAD_FAST_AND_CLEAR,
            PY_OP_STORE_FAST_LOAD_FAST,
            PY_OP_STORE_FAST_STORE_FAST,
            PY_OP_SWAP, PY_OP_GET_ITER, PY_OP_FOR_ITER,
            PY_OP_UNPACK_SEQUENCE, PY_OP_UNPACK_EX, PY_OP_TO_BOOL,
            PY_OP_CALL_INTRINSIC_1: begin
                id_rd_we = 1'b0; id_tos_delta = 3'sd0;
            end
            // PUSH_NULL: push sentinel {NULL, 0}, one RF write via WB stage.
            PY_OP_PUSH_NULL: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            // UNARY_*: rewrite TOS in place; net stack effect 0.
            PY_OP_UNARY_NOT, PY_OP_UNARY_INVERT, PY_OP_UNARY_NEGATIVE: begin
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
                if (route_container) begin
                    id_rd_we = 1'b0; id_tos_delta = 3'sd0;
                end else begin
                    id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
                end
            end
            PY_OP_COMPARE_OP, PY_OP_IS_OP: begin
                id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
            end
            PY_OP_END_FOR, PY_OP_POP_TOP, PY_OP_POP_ITER: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_RETURN_VALUE: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_RAISE_VARARGS: begin
                // CONT_RAISE pops TOS; keep WB delta at 0 for the container path.
                id_tos_delta = 3'sd0;
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
            // CONTAINS_OP / LIST_APPEND / LIST_EXTEND / SET_* fall through
            // default (same id_rd_we/tos_delta) and route via dec_is_container.
            PY_OP_BUILD_LIST, PY_OP_BUILD_MAP, PY_OP_BUILD_SET, PY_OP_BUILD_TUPLE,
            PY_OP_STORE_SUBSCR, PY_OP_DELETE_SUBSCR: begin
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
    assign binary_list_iadd = (cur_opcode_r == PY_OP_BINARY_OP) &&
                              (cur_arg_r[7:0] == 8'd13) &&
                              pycore_is_list(
                                  pycore_get_tag(rs1_r), pycore_get_val(rs1_r));
    assign route_container = dec_is_container || binary_list_iadd;
    assign is_alu = ((cur_opcode_r == PY_OP_BINARY_OP) && !route_container) ||
                    (cur_opcode_r == PY_OP_COMPARE_OP) ||
                    (cur_opcode_r == PY_OP_UNARY_INVERT) ||
                    (cur_opcode_r == PY_OP_UNARY_NEGATIVE);

    logic [PYCORE_ENTRY_WIDTH-1:0] exec_result;
    logic                          exec_stall;
    logic                          exec_trap;
    logic [4:0]                    exec_trap_code;
    logic                          string_exec_path_valid;
    logic [PYCORE_ENTRY_WIDTH-1:0] string_exec_result;
    logic                          string_exec_trap;
    logic [4:0]                    string_exec_trap_code;
    logic                          string_snapshot_valid;
    logic [3:0]                    string_snapshot_size;
    logic [119:0]                  string_snapshot_payload;
    logic                          string_snapshot_ok;
    logic [31:0]                   string_snapshot_addr;
    logic [31:0]                   string_read_addr;
    logic [31:0]                   string_read_data;

    pycore_string_mem #(
        .STRING_MEM_BYTES(STRING_MEM_BYTES),
        .STRING_MAX_LEN(STRING_MAX_LEN),
        .STRING_RUNTIME_BASE(STRING_RUNTIME_BASE),
        .STRING_HEX(STRING_HEX)
    ) string_store (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .exec_valid_i((state_r == S_EXEC) && is_alu),
        .exec_alu_op_i(dec_alu_op),
        .exec_rs1_i(rs1_r),
        .exec_rs2_i(rs2_r),
        .exec_path_valid_o(string_exec_path_valid),
        .exec_result_o(string_exec_result),
        .exec_trap_o(string_exec_trap),
        .exec_trap_code_o(string_exec_trap_code),
        .snapshot_valid_i(string_snapshot_valid),
        .snapshot_size_i(string_snapshot_size),
        .snapshot_payload_i(string_snapshot_payload),
        .snapshot_ok_o(string_snapshot_ok),
        .snapshot_addr_o(string_snapshot_addr),
        .read_addr_i(string_read_addr),
        .read_data_o(string_read_data)
    );

    pycore_exec exec (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .valid_i((state_r == S_EXEC) && is_alu),
        .alu_op_i(dec_alu_op),
        .rs1_i(rs1_r),
        .rs2_i(rs2_r),
        .string_path_valid_i(string_exec_path_valid),
        .string_result_i(string_exec_result),
        .string_trap_i(string_exec_trap),
        .string_trap_code_i(string_exec_trap_code),
        .result_o(exec_result),
        .stall_o(exec_stall),
        .trap_o(exec_trap),
        .trap_code_o(exec_trap_code)
    );

    logic        branch_take;
    logic [31:0] branch_tgt;
    logic        branch_trap;

    pycore_branch branch (
        .opcode_i(cur_opcode_r),
        .pc_i(cur_pc_r),
        .arg_i(cur_arg_r),
        .tos_entry_i(rs1_r),
        .take_branch_o(branch_take),
        .branch_target_o(branch_tgt),
        .trap_o(branch_trap),
        // Branch traps always fold into PY_TRAP_TYPE via type_trap_sig.
        .trap_code_o()
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
        exec_raise_pulse = 1'b0;
        ex_rs1_tag  = pycore_get_tag(rs1_r);
        ex_rs1_int  = rs1_r[63:0];
        ex_rs1_bool = 1'b0;
        unique case (cur_opcode_r)
            PY_OP_LOAD_SMALL_INT: ex_entry = pycore_int_entry({32'b0, cur_arg_r});
            PY_OP_BINARY_OP, PY_OP_COMPARE_OP,
            PY_OP_UNARY_INVERT, PY_OP_UNARY_NEGATIVE: ex_entry = exec_result;
            PY_OP_MEM_LOAD_PTR: begin
                ex_entry      = rs1_r;
                ex_addr_entry = rs1_r;
            end
            PY_OP_MEM_STORE_PTR: begin
                ex_entry      = rs1_r;
                ex_addr_entry = rs2_r;
            end
            // PUSH_NULL: emit the self_or_null sentinel entry.
            PY_OP_PUSH_NULL: ex_entry = pycore_make_control(PY_CTL_NULL);
            // DELETE_FAST: clear local to UNINIT; already-unbound → MEM_FAULT.
            PY_OP_DELETE_FAST: begin
                if (pycore_is_uninit(ex_rs1_tag, pycore_get_val(rs1_r))) begin
                    exec_mem_fault_pulse = (state_r == S_EXEC);
                end
                ex_entry = pycore_make_control(PY_CTL_UNINIT);
            end
            // LOAD_FAST_CHECK: push local like LOAD_FAST; unbound → MEM_FAULT.
            PY_OP_LOAD_FAST_CHECK: begin
                if (pycore_is_uninit(ex_rs1_tag, pycore_get_val(rs1_r))) begin
                    exec_mem_fault_pulse = (state_r == S_EXEC);
                end
                ex_entry = rs1_r;
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
            // RAISE_VARARGS 1 routes to CONT_RAISE (S_CONTAINER). Other arities
            // remain outside the supported subset.
            PY_OP_RAISE_VARARGS: begin
                if (cur_arg_r != 32'd1) begin
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
    logic [4:0]                    mem_trap_code;

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
    // The frame stack lives at the top of the 128 KB data memory
    // (byte addresses 0x1C000–0x1FFFF), leaving ~110 KB below for the object
    // heap.  STACK_BASE_ADDR must be within the dmem address window
    // (BLOCK_COUNT × 2^BLOCK_SHIFT = 32 × 4 KB = 128 KB).
    // ---------------------------------------------------------------------
    localparam int    RF_BASE_CORE          = STACK_BASE;
    localparam int    MAX_CALL_DEPTH_CORE   = 128;
    localparam logic [ADDR_WIDTH-1:0] FRAME_STACK_BASE = 32'h0001_C000;
    localparam int    FRAME_STACK_BYTES     = 32'h0000_4000;  // 16 KB, 512 frames

    logic [RF_AW-1:0]      frame_next_locals_base;
    logic                  frame_init_new_frame;
    logic                  frame_return_done;
    logic                  frame_fault_sig;
    logic                  frame_busy;
    logic [31:0]           frame_pc_return_out;
    logic [RF_AW-1:0]      frame_tos_base_out;
    logic [RF_AW-1:0]      frame_locals_base_out;
    logic [31:0]           frame_cur_code_out;
    logic                  frame_ret_mode_out;
    logic [63:0]           frame_saved_inst_out;
    logic [$clog2(MAX_CALL_DEPTH_CORE+1)-1:0] frame_active_depth;
    logic [$clog2(MAX_CALL_DEPTH_CORE+1)-1:0]
                          container_call_target_depth_r;

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
        .ret_mode_in_i(call_ret_mode_r),
        .saved_inst_in_i(call_saved_inst_r),
        .new_locals_base_in_i(call_new_locals_r),
        .pc_return_out_o(frame_pc_return_out),
        .tos_base_out_o(frame_tos_base_out),
        .locals_base_out_o(frame_locals_base_out),
        .cur_code_out_o(frame_cur_code_out),
        .ret_mode_out_o(frame_ret_mode_out),
        .saved_inst_out_o(frame_saved_inst_out),
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
                            return_wb_we_r    ? return_wb_data_r    :
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
        .init_from_i(rf_init_from_r),
        .init_until_i(rf_init_until_r),
        .push_stack_i(1'b0),
        .pop_stack_i(1'b0),
        .tos_ptr_o(),
        .locals_base_o(),
        .stack_fault_o()
    );

    // ---------------------------------------------------------------------
    // Dmem mux: four sources share the single dmem port.
    //   1. frame_dmem_active (S_CALL / S_RETURN): frame push/pop.
    //   2. container_dmem_active: heap alloc / element R/W (S_CONTAINER)
    //      AND boot-record + code-object field reads (S_BOOT, S_CALL,
    //      S_RETURN before frame_dmem_pending_r goes high).
    //   3. exc_dmem_active: exc-info stack push/pop (§5.5; step 5 opcodes).
    //   4. ms_dmem_* (S_MEM): normal PTR load/store.
    // Only one of container_dmem_pending_r / frame_dmem_pending_r may be
    // high at a time (the FSM issues them sequentially); S_MEM never
    // overlaps with 1 or 2.
    // ---------------------------------------------------------------------
    logic frame_dmem_active;
    logic container_dmem_active;
    logic exc_dmem_active;
    logic                  exc_push_valid;
    logic                  exc_pop_valid;
    logic [31:0]           exc_push_prev_ptr;
    logic                  exc_push_exc_valid;
    logic [3:0]            exc_push_exc_tag;
    logic [63:0]           exc_push_exc_addr;
    logic                  exc_push_ready;
    logic                  exc_push_fault;
    logic                  exc_pop_ready;
    logic                  exc_pop_fault;
    logic [31:0]           exc_pop_prev_ptr;
    logic                  exc_pop_exc_valid;
    logic [3:0]            exc_pop_exc_tag;
    logic [63:0]           exc_pop_exc_addr;
    logic                  exc_dmem_req;
    logic                  exc_dmem_we;
    logic [ADDR_WIDTH-1:0] exc_dmem_addr;
    logic [127:0]          exc_dmem_wdata;
    logic [ADDR_WIDTH-1:0] exc_sp;
    logic [ADDR_WIDTH-1:0] exc_head;
    logic                  exc_empty;
    logic                  exc_full;

    // Driven by CONT_PUSH_EXC_INFO / CONT_POP_EXCEPT / CONT_RERAISE.
    logic        exc_push_valid_r;
    logic [31:0] exc_push_prev_ptr_r;
    logic        exc_push_exc_valid_r;
    logic [3:0]  exc_push_exc_tag_r;
    logic [63:0] exc_push_exc_addr_r;
    logic        exc_pop_valid_r;

    assign exc_push_valid     = exc_push_valid_r;
    assign exc_pop_valid      = exc_pop_valid_r;
    assign exc_push_prev_ptr  = exc_push_prev_ptr_r;
    assign exc_push_exc_valid = exc_push_exc_valid_r;
    assign exc_push_exc_tag   = exc_push_exc_tag_r;
    assign exc_push_exc_addr  = exc_push_exc_addr_r;

    pycore_exc_stack #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_exc_stack (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .exc_sp_o(exc_sp),
        .exc_head_o(exc_head),
        .empty_o(exc_empty),
        .full_o(exc_full),
        .push_valid_i(exc_push_valid),
        .push_prev_ptr_i(exc_push_prev_ptr),
        .push_exc_valid_i(exc_push_exc_valid),
        .push_exc_tag_i(exc_push_exc_tag),
        .push_exc_addr_i(exc_push_exc_addr),
        .push_ready_o(exc_push_ready),
        .push_fault_o(exc_push_fault),
        .pop_valid_i(exc_pop_valid),
        .pop_ready_o(exc_pop_ready),
        .pop_fault_o(exc_pop_fault),
        .pop_prev_ptr_o(exc_pop_prev_ptr),
        .pop_exc_valid_o(exc_pop_exc_valid),
        .pop_exc_tag_o(exc_pop_exc_tag),
        .pop_exc_addr_o(exc_pop_exc_addr),
        .dmem_req_o(exc_dmem_req),
        .dmem_we_o(exc_dmem_we),
        .dmem_addr_o(exc_dmem_addr),
        .dmem_wdata_o(exc_dmem_wdata),
        .dmem_ack_i(dmem_ack_i),
        .dmem_rdata_i(dmem_rdata_i)
    );

    assign frame_dmem_active     = frame_dmem_pending_r &&
                                   ((state_r == S_CALL) || (state_r == S_RETURN));
    assign container_dmem_active = container_dmem_pending_r &&
                                   ((state_r == S_CONTAINER) ||
                                    (state_r == S_BOOT)      ||
                                    (state_r == S_CALL)      ||
                                    (state_r == S_RETURN));
    assign exc_dmem_active       = exc_dmem_req &&
                                   !frame_dmem_active && !container_dmem_active;

    assign dmem_req_o   = frame_dmem_active     ? 1'b1 :
                          container_dmem_active ? 1'b1 :
                          exc_dmem_active       ? 1'b1 : ms_dmem_req;
    assign dmem_we_o    = frame_dmem_active     ? (state_r == S_CALL) :
                          container_dmem_active ? container_dmem_we_r  :
                          exc_dmem_active       ? exc_dmem_we         : ms_dmem_we;
    assign dmem_addr_o  = frame_dmem_active     ?
                              ((state_r == S_CALL) ? frame_push_addr : frame_pop_addr) :
                          container_dmem_active ? container_dmem_addr_r :
                          exc_dmem_active       ? exc_dmem_addr        : ms_dmem_addr;
    assign dmem_wdata_o = frame_dmem_active     ? frame_push_data :
                          container_dmem_active ? container_dmem_wdata_r :
                          exc_dmem_active       ? exc_dmem_wdata       : ms_dmem_wdata;

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
    // RAISE_VARARGS bad arity, and UNARY_NOT (non-BOOL) type checks that ride
    // the EX stage combinationally.
    // exec_mem_fault_pulse covers DELETE_FAST on an already-unbound local
    // and LOAD_FAST_CHECK on an unbound local (UnboundLocalError analog →
    // PY_TRAP_MEM_FAULT).
    logic exec_type_trap_pulse;
    logic exec_mem_fault_pulse;
    logic exec_raise_pulse;
    assign type_trap_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_TYPE)) ||
                            (exec_in && dec_is_branch && branch_trap) ||
                            exec_type_trap_pulse ||
                            container_type_trap_r ||
                            (container_attr_error_r && container_proto_resolve_r) ||
                            return_type_trap_r;
    assign stack_fault_sig = (state_r == S_WB) && !dec_is_call && !dec_is_return &&
                              !route_container &&
                             ((next_tos < STACK_BASE) || (next_tos > STACK_TOP_MAX));
    assign div_zero_sig   = exec_in && exec_trap && (exec_trap_code == PY_TRAP_DIV_ZERO);
    assign fpu_exc_sig    = exec_in && exec_trap && (exec_trap_code == PY_TRAP_FPU_EXCEPTION);
    assign illegal_sig    = (exec_in && dec_illegal) ||
                            (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ILLEGAL_OPCODE));
    // Container/boot/frame dmem transactions bypass pycore_mem_stage, so
    // dmem_fault_i must be folded in here whenever those owners hold the port.
    assign mem_fault_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_MEM_FAULT)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_MEM_FAULT)) ||
                            exec_mem_fault_pulse ||
                            container_mem_fault_r ||
                            imem_fault_i ||
                            ((container_dmem_active || frame_dmem_active ||
                              exc_dmem_active) &&
                             dmem_ack_i && dmem_fault_i);
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
    logic list_delete_sig;
    logic set_grow_sig;
    logic set_update_sig;
    assign dict_grow_sig      = container_dict_grow_trap_r;
    assign list_delete_sig    = container_list_delete_trap_r;
    assign set_grow_sig       = container_set_grow_trap_r;
    assign set_update_sig     = container_set_update_trap_r;
    logic attr_error_sig;
    // Protocol resolve treats ATTR miss as TYPE (no __iter__/__next__).
    assign attr_error_sig     = container_attr_error_r && !container_proto_resolve_r;
    logic raise_sig;
    assign raise_sig          = exec_raise_pulse || container_raise_trap_r;
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
        .set_grow_i(set_grow_sig),
        .set_update_i(set_update_sig),
        .attr_error_i(attr_error_sig),
        .raise_i(raise_sig),
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
    logic         cont_rs1_contam; // contamination bit of rs1 handle
    logic         cont_rs2_contam; // contamination bit of rs2 handle
    logic         cont_iter_valid;
    logic [3:0]   cont_iter_kind;
    logic [31:0]  cont_iter_index;
    logic [31:0]  cont_iter_size;
    logic [31:0]  cont_iter_addr;
    logic [19:0]  cont_iter_aux;

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
    assign cont_tuple_size_rs2 = pycore_tuple_size(cont_rs2_val);
    assign cont_tuple_addr_rs2 = cont_rs2_val[31:0];
    assign cont_ext_hdr_len    = pycore_list_length(container_list_hdr_r);
    assign cont_rs1_tag   = pycore_get_tag(rs1_r);
    assign cont_rs2_tag   = pycore_get_tag(rs2_r);
    assign cont_rf_rs1_val = pycore_get_val(rf_rs1);
    assign cont_rf_rs1_tag = pycore_get_tag(rf_rs1);
    // Contamination bits on the MUT_COLLEC handle operands (value[123]).
    // Contamination bit is only meaningful on MUT_COLLEC (and reserved
    // FROZENSET) handles. Reading value[123] on a TUPLE would alias size bits.
    assign cont_rs1_contam = (cont_rs1_tag == PY_TAG_MUT_COLLEC) &&
                             pycore_mut_contaminated(cont_rs1_val);
    assign cont_rs2_contam = (cont_rs2_tag == PY_TAG_MUT_COLLEC) &&
                             pycore_mut_contaminated(cont_rs2_val);
    assign cont_iter_valid    = pycore_iter_valid(cont_rs1_val);
    assign cont_iter_kind     = pycore_iter_kind(cont_rs1_val);
    assign cont_iter_index    = pycore_iter_index(cont_rs1_val);
    assign cont_iter_size     = pycore_iter_size(cont_rs1_val);
    assign cont_iter_addr     = pycore_iter_addr(cont_rs1_val);
    assign cont_iter_aux      = pycore_iter_aux(cont_rs1_val);
    assign string_snapshot_size = pycore_short_str_size(cont_rs1_val);
    assign string_snapshot_payload = pycore_short_str_payload(cont_rs1_val);
    assign string_snapshot_valid =
        (state_r == S_CONTAINER) &&
        (container_op_r == CONT_GET_ITER) &&
        (container_phase_r == CP_INIT) &&
        (cont_rs1_tag == PY_TAG_SHORT_STR) &&
        (string_snapshot_size != 4'b0);
    assign string_read_addr = cont_iter_addr + cont_iter_index;

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

    // **kwargs dict being packed by the CALL binder (subs 52-55).  The object,
    // its order sidecar and its hash table are allocated contiguously, exactly
    // like BUILD_MAP, so only base + slot count need to be carried around.
    logic [31:0] cont_varkw_base;
    logic [31:0] cont_varkw_slots;
    logic [31:0] cont_varkw_order_ptr;
    logic [31:0] cont_varkw_table_ptr;
    assign cont_varkw_base      = call_varkw_dict_r[31:0];
    assign cont_varkw_slots     = call_varkw_dict_r[63:32];
    assign cont_varkw_order_ptr = cont_varkw_base + 32'd48;
    assign cont_varkw_table_ptr = cont_varkw_base + 32'd48 +
                                  (cont_varkw_slots << 5);

    // Probe advance inside the **kwargs table: (probe + 1) & (slots - 1).
    logic [31:0] cont_varkw_probe_next;
    assign cont_varkw_probe_next = (container_probe_r + 32'd1) &
                                   (cont_varkw_slots - 32'd1);

    // Combinational helper used only when latching scratch bases in sub 34.
    // Prefer call_argcount (includes self for method form) over n_pos so
    // bound-method CALL_KW copies from the correct stack slots.  Do not use
    // this wire after *args packing — argc has changed by then.
    logic [15:0] call_kw_scratch_base_now;
    always_comb begin
        logic [15:0] locals_end;
        call_kw_scratch_base_now = call_argcount_r + {8'b0, call_n_kwargs_r};
        locals_end = call_total_params_r
                     + (call_varargs_r ? 16'd1 : 16'd0)
                     + (call_varkw_r ? 16'd1 : 16'd0);
        if ((call_varargs_r || call_varkw_r) &&
            (call_kw_scratch_base_now < locals_end))
            call_kw_scratch_base_now = locals_end;
    end

    logic cont_set_needs_grow;
    assign cont_set_needs_grow = pycore_set_needs_grow(
        container_used_r, {32'b0, container_slot_count_r});

    logic [31:0] cont_set_min_slots;
    assign cont_set_min_slots = pycore_set_min_slots(container_count_r);

    // Load-factor / empty-table check before a new-key dict insert.
    logic cont_dict_needs_grow;
    assign cont_dict_needs_grow = pycore_dict_needs_grow(
        container_used_r, {32'b0, container_slot_count_r});

    // DICT v3 packed pointer slot: order_ptr high, table_ptr low.
    logic [31:0] cont_dict_table_ptr;
    logic [31:0] cont_dict_order_ptr;
    assign cont_dict_table_ptr = container_rd_data_r[31:0];
    assign cont_dict_order_ptr = container_rd_data_r[95:64];

    // CONTAINS_OP: compare scanned element (value latched in container_val_r,
    // tag in container_rd_data_r[3:0] during CP_TAG) against needle rs1.
    logic cont_contains_eq;
    assign cont_contains_eq = pycore_elem_eq(
        container_rd_data_r[3:0], container_val_r,
        cont_rs1_tag, cont_rs1_val);

    // Probe advance: (probe + 1) & mask.
    logic [31:0] cont_probe_next;
    assign cont_probe_next = (container_probe_r + 32'd1) & (container_slot_count_r - 32'd1);

    // UNPACK_EX helpers.  These are only meaningful after the source length
    // has been validated as >= before+after.
    logic [31:0] cont_unpack_fixed_len;
    logic [31:0] cont_unpack_rest_len;
    logic [31:0] cont_unpack_middle_alloc;
    assign cont_unpack_fixed_len = {24'd0, container_unpack_before_r} +
                                   {24'd0, container_unpack_after_r};
    assign cont_unpack_rest_len = container_src_len_r - cont_unpack_fixed_len;
    assign cont_unpack_middle_alloc = pycore_list_obj_bytes() +
        ((cont_unpack_rest_len == 32'd0) ? 32'd0 :
         pycore_list_buf_bytes(cont_unpack_rest_len));

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
    localparam logic [4:0] CALL_PHASE_DONE     = 5'd15;
    localparam logic [4:0] CALL_PHASE_KW_NAMES = 5'd16;
    localparam logic [4:0] CALL_PHASE_EX_KW    = 5'd17;
    localparam logic [4:0] CALL_PHASE_EX_ARGS  = 5'd18;
    localparam logic [4:0] CALL_PHASE_EX_EXPAND = 5'd19;
    localparam logic [2:0] RET_PHASE_DONE  = 3'd7;
    localparam logic [3:0] BOOT_PHASE_DONE = 4'd15;
    // call_mode_r encodings
    localparam logic [1:0] CALL_MODE_POS   = 2'd0; // plain CALL
    localparam logic [1:0] CALL_MODE_KW    = 2'd1; // CALL_KW (names tuple)
    localparam logic [1:0] CALL_MODE_EX    = 2'd2; // CALL_FUNCTION_EX expand
    localparam logic [1:0] CALL_MODE_EX_KW = 2'd3; // EX with kwargs dict binder
    // SHORT_STR value for "__init__" (size=8); used by TYPE-call tp_dict probe.
    localparam logic [127:0] CALL_INIT_NAME_VAL =
        128'h85f5f696e69745f5f000000000000000;
    // SHORT_STR value for "__len__" (size=7); used by builtins.len instance probe.
    localparam logic [127:0] CALL_LEN_NAME_VAL =
        128'h75f5f6c656e5f5f00000000000000000;
    // Empty dict for new instances: 4 slots (BUILD_MAP min for 0 pairs).
    localparam logic [31:0] CALL_EMPTY_DICT_SLOTS = 32'd4;
    localparam logic [31:0] CALL_TYPE_ALLOC_BYTES =
        32'd48 + (CALL_EMPTY_DICT_SLOTS << 5) +
        (CALL_EMPTY_DICT_SLOTS << 6) + PYCORE_OBJ_INSTANCE_BYTES;

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
                        if (route_container) state_next = S_CONTAINER;
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
                    // Builtin CALL may raise PY_TRAP_BUILTIN_CALL via
                    // trap_marshal_pending_r before CALL_PHASE_DONE.
                    if (call_phase_r == CALL_PHASE_DONE)
                        state_next = trap_marshal_pending_r ? S_TRAP_MARSHAL
                                                           : S_FETCH;
                end
                S_RETURN: begin
                    // Multi-phase RETURN: frame pop, then two dmem reads to
                    // reload caller's co_consts / co_names before redirect.
                    // A container-launched outer call resumes its paused
                    // S_CONTAINER arm; nested ordinary calls still fetch.
                    // Protocol raise unwind (§6.1.1) also resumes S_CONTAINER.
                    if (return_phase_r == RET_PHASE_DONE)
                        state_next = container_call_returning_r
                                   ? S_CONTAINER : S_FETCH;
                end
                S_CONTAINER: begin
                    // CP_DONE is a terminal marker phase used uniformly by all
                    // sub-operations.  All actual work (RF write, TOS update) is
                    // committed in the cycle that advances container_phase_r to
                    // CP_DONE, so the CP_DONE always_ff case is intentionally empty.
                    // trap_marshal_pending_r (Phase C, EXCORE_EN=1) redirects the
                    // exit to S_TRAP_MARSHAL instead of S_FETCH.
                    if (container_call_pending_r) begin
                        state_next = S_CALL;
                    end else if (container_call_exc_unwind_r) begin
                        state_next = S_RETURN;
                    end else if (container_phase_r == CP_DONE) begin
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
            rf_init_from_r       <= '0;
            rf_init_until_r      <= '0;
            return_wb_we_r       <= 1'b0;
            return_wb_addr_r     <= '0;
            // Arch regs for image boot.
            cur_code_r           <= '0;
            consts_base_r        <= '0;
            names_base_r         <= '0;
            globals_base_r       <= '0;
            builtins_base_r      <= '0;
            call_phase_r         <= '0;
            return_phase_r       <= '0;
            boot_phase_r         <= '0;
            call_mode_r          <= 2'd0; // CALL_MODE_POS
            call_n_pos_r         <= '0;
            call_n_kwargs_r      <= '0;
            call_kw_val_base_r   <= '0;
            call_kw_scratch_base_r <= '0;
            call_kw_names_r      <= '0;
            call_varnames_r      <= '0;
            call_kwdefaults_r    <= '0;
            call_kwonly_r        <= '0;
            call_total_params_r  <= '0;
            call_varargs_r       <= 1'b0;
            call_varkw_r         <= 1'b0;
            call_posonly_r       <= '0;
            call_varkw_dict_r    <= '0;
            call_varkw_left_r    <= '0;
            call_varkw_step_r    <= '0;
            call_varkw_alloced_r <= 1'b0;
            call_after_varargs_sub_r <= '0;
            call_varargs_to_frame_r  <= 1'b0;
            call_args_is_list_r  <= 1'b0;
            call_code_addr_r     <= '0;
            call_entry_slot_r    <= '0;
            call_consts_r        <= '0;
            call_names_r         <= '0;
            call_argcount_r      <= '0;
            call_meta_argc_r     <= '0;
            call_nlocals_r       <= '0;
            call_new_locals_r    <= '0;
            call_tos_base_r      <= '0;
            call_obj_addr_r      <= '0;
            call_defaults_r      <= '0;
            call_defaults_len_r  <= '0;
            call_min_argc_r      <= '0;
            call_sub_r           <= '0;
            call_self_tag_r      <= '0;
            call_self_val_r      <= '0;
            call_range_start_r   <= '0;
            call_range_stop_r    <= '0;
            call_range_step_r    <= '0;
            call_inst_addr_r     <= '0;
            call_ret_mode_r      <= 1'b0;
            call_saved_inst_r    <= '0;
            frame_ret_mode_r     <= 1'b0;
            frame_saved_inst_r   <= '0;
            container_call_target_depth_r <= '0;
            call_filter_trap_r   <= 1'b0;
            return_type_trap_r   <= 1'b0;
            return_wb_data_r     <= '0;
            // Container / heap allocator reset.
            heap_ptr_r               <= HEAP_INIT_PTR;
            container_op_r           <= '0;
            container_phase_r        <= '0;
            container_call_pending_r <= 1'b0;
            container_call_active_r <= 1'b0;
            container_call_returning_r <= 1'b0;
            container_call_return_valid_r <= 1'b0;
            container_call_result_r <= '0;
            container_call_saved_op_r <= '0;
            container_call_saved_phase_r <= '0;
            container_call_saved_opcode_r <= '0;
            container_call_saved_arg_r <= '0;
            container_call_saved_pc_r <= '0;
            container_call_saved_tos_r <= '0;
            container_call_saved_rs1_r <= '0;
            container_call_saved_rs2_r <= '0;
            call_exc_pending_r <= 1'b0;
            call_exc_handle_r <= '0;
            call_exc_type_r <= '0;
            container_call_exc_unwind_r <= 1'b0;
            container_proto_resolve_r <= 1'b0;
            container_proto_op_r <= '0;
            container_proto_iter_r <= '0;
            raise_type_entry_r <= '0;
            container_idx_r          <= '0;
            container_count_r        <= '0;
            container_base_r         <= '0;
            container_tag_r          <= '0;
            container_val_r          <= '0;
            container_range_start_r  <= '0;
            container_range_stop_r   <= '0;
            container_range_step_r   <= '0;
            container_rf_addr_r      <= '0;
            container_rd_data_r      <= '0;
            container_slot_count_r   <= '0;
            container_probe_r        <= '0;
            container_val_rf_addr_r  <= '0;
            container_used_r         <= '0;
            container_order_ptr_r     <= '0;
            container_order_len_r     <= '0;
            container_dict_version_r  <= '0;
            container_order_idx_r     <= '0;
            container_order_key_tag_r <= '0;
            container_order_shift_val_r <= '0;
            container_order_shift_tag_r <= '0;
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
            container_raise_trap_r   <= 1'b0;
            active_exc_r             <= '0;
            active_exc_valid_r       <= 1'b0;
            iter_exhaust_type_r      <= '0;
            exc_push_valid_r         <= 1'b0;
            exc_push_prev_ptr_r      <= '0;
            exc_push_exc_valid_r     <= 1'b0;
            exc_push_exc_tag_r       <= '0;
            exc_push_exc_addr_r      <= '0;
            exc_pop_valid_r          <= 1'b0;
            container_attr_error_r   <= 1'b0;
            container_buf_r          <= '0;
            container_list_hdr_r     <= '0;
            container_list_grow_trap_r   <= 1'b0;
            container_src_buf_r          <= '0;
            container_src_len_r          <= '0;
            container_src_is_tuple_r     <= 1'b0;
            container_unpack_before_r    <= '0;
            container_unpack_after_r     <= '0;
            container_unpack_mode_r      <= '0;
            container_list_extend_trap_r <= 1'b0;
            container_list_delete_trap_r <= 1'b0;
            container_dict_grow_trap_r      <= 1'b0;
            container_set_grow_trap_r       <= 1'b0;
            container_set_update_trap_r     <= 1'b0;
            container_probe_tag_r           <= '0;
            container_tomb_valid_r          <= 1'b0;
            container_tomb_idx_r            <= '0;
            container_contam_r              <= 1'b0;
            container_src_base_r            <= '0;
            container_src_slots_r           <= '0;
            container_src_idx_r             <= '0;
            container_dst_rf_addr_r         <= '0;
            container_old_table_r           <= '0;
            container_old_slots_r           <= '0;
            container_bulk_mode_r           <= '0;
            container_src_kind_r            <= '0;
            container_bulk_size_r           <= '0;
            container_old_order_r           <= '0;
            trap_marshal_pending_r     <= 1'b0;
            trap_marshal_code_r        <= '0;
            trap_marshal_entry_count_r <= '0;
            trap_marshal_entries_r[0]  <= '0;
            trap_marshal_entries_r[1]  <= '0;
            trap_marshal_entries_r[2]  <= '0;
            trap_marshal_entries_r[3]  <= '0;
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
            return_type_trap_r   <= 1'b0;
            container_wb_we_r     <= 1'b0;
            container_type_trap_r  <= 1'b0;
            container_mem_fault_r  <= 1'b0;
            container_raise_trap_r <= 1'b0;
            container_attr_error_r <= 1'b0;
            container_list_grow_trap_r   <= 1'b0;
            container_list_extend_trap_r <= 1'b0;
            container_list_delete_trap_r <= 1'b0;
            container_dict_grow_trap_r      <= 1'b0;
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
                        if (route_container) begin
                            container_phase_r        <= CP_INIT;
                            container_dmem_pending_r <= 1'b0;
                            container_type_trap_r    <= 1'b0;
                            container_mem_fault_r    <= 1'b0;
                            container_raise_trap_r   <= 1'b0;
                            container_attr_error_r   <= 1'b0;
                            container_wb_we_r        <= 1'b0;
                            container_contam_r       <= 1'b0;
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
                                container_op_r <= (pycore_is_dict(cont_rs2_tag, cont_rs2_val)) ?
                                                  CONT_STORE_DICT : CONT_STORE_LIST;
                            end else if (cur_opcode_r == PY_OP_DELETE_SUBSCR) begin
                                // DICT → tombstone path; LIST → shift-down;
                                // SET / other → TYPE in CONT_DELETE_LIST.
                                container_op_r <= (pycore_is_dict(cont_rs2_tag, cont_rs2_val)) ?
                                                  CONT_DELETE_DICT : CONT_DELETE_LIST;
                            end else if (cur_opcode_r == PY_OP_CONTAINS_OP) begin
                                // rs1 = needle, rs2 = container.
                                if (pycore_is_dict(cont_rs2_tag, cont_rs2_val))
                                    container_op_r <= CONT_CONTAINS_DICT;
                                else if (pycore_is_set(cont_rs2_tag, cont_rs2_val))
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
                            end else if ((cur_opcode_r == PY_OP_LIST_EXTEND) ||
                                         binary_list_iadd) begin
                                container_op_r <= CONT_LIST_EXTEND;
                            end else if (cur_opcode_r == PY_OP_SET_ADD) begin
                                container_op_r <= CONT_SET_ADD;
                            end else if (cur_opcode_r == PY_OP_SET_UPDATE) begin
                                container_op_r <= CONT_SET_UPDATE;
                            end else if (cur_opcode_r == PY_OP_DICT_MERGE) begin
                                container_op_r <= CONT_DICT_MERGE;
                            end else if (cur_opcode_r == PY_OP_DICT_UPDATE) begin
                                container_op_r <= CONT_DICT_UPDATE;
                            end else if (cur_opcode_r == PY_OP_MAP_ADD) begin
                                container_op_r <= CONT_MAP_ADD;
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
                            end else if (cur_opcode_r == PY_OP_GET_ITER) begin
                                container_op_r <= CONT_GET_ITER;
                            end else if (cur_opcode_r == PY_OP_FOR_ITER) begin
                                container_op_r <= CONT_FOR_ITER;
                            end else if (cur_opcode_r == PY_OP_SWAP) begin
                                container_op_r <= CONT_SWAP;
                            end else if (cur_opcode_r == PY_OP_LOAD_ATTR) begin
                                container_op_r        <= CONT_LOAD_ATTR;
                                container_push_null_r <= cur_arg_r[0]; // method_flag
                            end else if (cur_opcode_r == PY_OP_STORE_ATTR) begin
                                container_op_r <= CONT_STORE_ATTR;
                            end else if (cur_opcode_r == PY_OP_DELETE_ATTR) begin
                                container_op_r <= CONT_DELETE_ATTR;
                            end else if (cur_opcode_r == PY_OP_UNPACK_SEQUENCE) begin
                                container_op_r    <= CONT_UNPACK_SEQ;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_UNPACK_EX) begin
                                container_op_r             <= CONT_UNPACK_EX;
                                container_unpack_before_r  <= cur_arg_r[7:0];
                                container_unpack_after_r   <= cur_arg_r[15:8];
                                container_unpack_mode_r    <= 2'd0;
                                container_count_r          <= 7'd0;
                                container_idx_r            <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_TO_BOOL) begin
                                container_op_r <= CONT_TO_BOOL;
                            end else if (cur_opcode_r == PY_OP_CALL_INTRINSIC_1) begin
                                container_op_r <= CONT_LIST_TO_TUPLE;
                            end else if (cur_opcode_r == PY_OP_BINARY_OP) begin
                                // BINARY_OP/NB_SUBSCR: rs1 = container.
                                if (pycore_is_dict(cont_rs1_tag, cont_rs1_val))
                                    container_op_r <= CONT_SUBSCR_DICT;
                                else if (cont_rs1_tag == PY_TAG_TUPLE)
                                    container_op_r <= CONT_SUBSCR_TUPLE;
                                else
                                    container_op_r <= CONT_SUBSCR_LIST;
                            end else if (cur_opcode_r == PY_OP_RAISE_VARARGS) begin
                                container_op_r <= CONT_RAISE;
                            end else if (cur_opcode_r == PY_OP_PUSH_EXC_INFO) begin
                                container_op_r <= CONT_PUSH_EXC_INFO;
                            end else if (cur_opcode_r == PY_OP_CHECK_EXC_MATCH) begin
                                container_op_r <= CONT_CHECK_EXC_MATCH;
                            end else if (cur_opcode_r == PY_OP_POP_EXCEPT) begin
                                container_op_r <= CONT_POP_EXCEPT;
                            end else if (cur_opcode_r == PY_OP_RERAISE) begin
                                container_op_r <= CONT_RERAISE;
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
                        // CALL / CALL_KW / CALL_FUNCTION_EX: multi-phase FSM.
                        // Phase 0 → RF settle at callable (or KW/EX prelude).
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        call_phase_r         <= 5'd0;
                        call_sub_r           <= 6'd0;
                        call_ret_mode_r      <= 1'b0;
                        call_saved_inst_r    <= 64'b0;
                        if (cur_opcode_r == PY_OP_CALL_KW)
                            call_mode_r <= CALL_MODE_KW;
                        else if (cur_opcode_r == PY_OP_CALL_FUNCTION_EX)
                            call_mode_r <= CALL_MODE_EX;
                        else
                            call_mode_r <= CALL_MODE_POS;
                        call_n_pos_r        <= '0;
                        call_n_kwargs_r     <= '0;
                        call_kw_val_base_r  <= '0;
                        call_kw_scratch_base_r <= '0;
                        call_varargs_r      <= 1'b0;
                        call_varkw_r        <= 1'b0;
                        call_posonly_r      <= '0;
                        call_varkw_left_r   <= '0;
                        call_varkw_step_r   <= '0;
                        call_varkw_alloced_r <= 1'b0;
                        call_after_varargs_sub_r <= '0;
                        call_varargs_to_frame_r  <= 1'b0;
                        call_args_is_list_r <= 1'b0;
                        container_dmem_pending_r <= 1'b0;
                        fetch_skip_r         <= 1'b1;
                        // state_next = S_CALL (from always_comb)

                    end else begin
                        // RETURN_VALUE.
                        if (frame_active_depth > 0) begin
                            // There is a calling frame: pop the frame, reload
                            // caller consts/names, then redirect.
                            // Depth identifies the outer protocol frame even
                            // when its callee made ordinary nested calls.
                            container_call_returning_r <=
                                container_call_active_r &&
                                (frame_active_depth ==
                                 container_call_target_depth_r);
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

                `include "pycore_call_fsm.svh"

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

                    // ---- Container-launched CALL handoff --------------------
                    // The requesting arm has already staged the regular CALL
                    // stack layout and moved to its wait phase.  Snapshot the
                    // state that bytecode execution will overwrite, then enter
                    // the existing positional CALL FSM without a second CALL
                    // implementation.
                    if (container_call_pending_r) begin
                        container_call_pending_r <= 1'b0;
                        container_call_active_r <= 1'b1;
                        container_call_return_valid_r <= 1'b0;
                        container_call_saved_op_r <= container_op_r;
                        container_call_saved_phase_r <= container_phase_r;
                        container_call_saved_opcode_r <= cur_opcode_r;
                        container_call_saved_arg_r <= cur_arg_r;
                        container_call_saved_pc_r <= cur_pc_r;
                        container_call_saved_tos_r <= tos_r;
                        // HEAP_ITER protocol: rs1 holds the OBJECT receiver for
                        // CALL; the ITER hybrid was stashed in proto_iter_r.
                        container_call_saved_rs1_r <=
                            (container_op_r == CONT_FOR_ITER &&
                             container_phase_r == CP_COPY_VAL_WB)
                                ? container_proto_iter_r : rs1_r;
                        container_call_saved_rs2_r <= rs2_r;
                        container_call_target_depth_r <= frame_active_depth + 1'b1;
                        // __iter__ / __next__ use CALL 0.  Preserve the
                        // container oparg above (FOR_ITER needs its jump delta)
                        // and present zero positional args to S_CALL; a staged
                        // non-NULL self is counted by the existing method path.
                        cur_arg_r <= 32'd0;

                        // Match S_EXEC CALL entry reset so leftover binder
                        // scratch (CALL_KW / **kwargs / posonly) cannot leak
                        // into a protocol CALL 0 for __iter__/__next__.
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        call_phase_r         <= 5'd0;
                        call_sub_r           <= 6'd0;
                        call_ret_mode_r      <= 1'b0;
                        call_saved_inst_r    <= 64'b0;
                        call_mode_r          <= CALL_MODE_POS;
                        call_n_pos_r         <= '0;
                        call_n_kwargs_r      <= '0;
                        call_kw_val_base_r   <= '0;
                        call_kw_scratch_base_r <= '0;
                        call_varargs_r       <= 1'b0;
                        call_varkw_r         <= 1'b0;
                        call_posonly_r       <= '0;
                        call_varkw_left_r    <= '0;
                        call_varkw_step_r    <= '0;
                        call_varkw_alloced_r <= 1'b0;
                        call_after_varargs_sub_r <= '0;
                        call_varargs_to_frame_r  <= 1'b0;
                        call_args_is_list_r  <= 1'b0;
                        container_dmem_pending_r <= 1'b0;
                        fetch_skip_r         <= 1'b1;
                    end else begin
                        // ---- Per-operation phase logic ----------------------
                        unique case (container_op_r)

                            // =================================================
                            // LIST / TUPLE / iterator ops
                            `include "pycore_cont_list.svh"

                            // DICT / SET ops
                            `include "pycore_cont_dict.svh"

                            // Bulk DICT_UPDATE / DICT_MERGE / SET_UPDATE —
                            // excore fast paths plus pycore rehash loops.
                            `include "pycore_cont_bulk.svh"

                            // Name/global/RF helpers (+ future object attrs)
                            `include "pycore_cont_object.svh"

                            // RAISE_VARARGS 1 (§7.5)
                            `include "pycore_cont_raise.svh"

                            // Handler opcodes (§7.3 / §7.6)
                            `include "pycore_cont_exc.svh"

                            default: ;

                        endcase
                    end
                end // S_CONTAINER

                // ----------------------------------------------------------
                // S_BOOT: image-boot reset walker.  Runs once at cold start
                // when BOOT_EN=1.  Sequence:
                //
                //   Phase 0 : issue boot record pair0 VAL read.
                //   Phase 1 : latch code_obj addr; issue pair0 TAG read.
                //   Phase 2 : verify tag == CODE_OBJECT; issue pair1 VAL.
                //   Phase 3 : latch globals dict addr; issue pair1 TAG.
                //   Phase 4 : verify globals DICT; issue builtins VAL (+64).
                //   Phase 5 : latch builtins_base_r; issue builtins TAG (+80).
                //   Phase 6 : verify builtins DICT; issue entry_slot.
                //   Phase 7 : latch entry_slot; issue co_consts.
                //   Phase 8 : latch consts_base_r; issue co_names.
                //   Phase 9 : latch names_base_r; issue StopIteration sidecar VAL.
                //   Phase 10: latch sidecar VAL; issue sidecar TAG.
                //   Phase 11: latch iter_exhaust_type_r; redirect fetch.
                //   Phase 15: terminal marker → S_FETCH.
                //
                // Boot record layout (see pycore_defs.svh):
                //   PYCORE_BOOT_RECORD_ADDR + 0  : module code object VAL
                //   PYCORE_BOOT_RECORD_ADDR + 16 : module code object TAG
                //   PYCORE_BOOT_RECORD_ADDR + 32 : globals dict VAL
                //   PYCORE_BOOT_RECORD_ADDR + 48 : globals dict TAG
                //   PYCORE_BOOT_RECORD_ADDR + 64 : builtins dict VAL
                //   PYCORE_BOOT_RECORD_ADDR + 80 : builtins dict TAG
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
                                if (container_rd_data_r[3:0] !=
                                        PY_TAG_MUT_COLLEC) begin
                                    container_mem_fault_r <= 1'b1;
                                end else begin
                                    container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR + 32'd64;
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    boot_phase_r             <= 4'd5;
                                end
                            end
                        end

                        4'd5: begin
                            if (!container_dmem_pending_r) begin
                                builtins_base_r <= container_rd_data_r[31:0];
                                container_dmem_addr_r    <= PYCORE_BOOT_RECORD_ADDR + 32'd80;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd6;
                            end
                        end

                        4'd6: begin
                            if (!container_dmem_pending_r) begin
                                if (container_rd_data_r[3:0] !=
                                        PY_TAG_MUT_COLLEC) begin
                                    container_mem_fault_r <= 1'b1;
                                end else begin
                                    container_dmem_addr_r    <= pycore_code_field_val_addr(
                                        cur_code_r, PYCORE_CODE_FIELD_ENTRY_SLOT);
                                    container_dmem_we_r      <= 1'b0;
                                    container_dmem_pending_r <= 1'b1;
                                    boot_phase_r             <= 4'd7;
                                end
                            end
                        end

                        4'd7: begin
                            if (!container_dmem_pending_r) begin
                                call_entry_slot_r <= container_rd_data_r[63:0];
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_CONSTS);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd8;
                            end
                        end

                        4'd8: begin
                            if (!container_dmem_pending_r) begin
                                consts_base_r <= container_rd_data_r;
                                container_dmem_addr_r    <= pycore_code_field_val_addr(
                                    cur_code_r, PYCORE_CODE_FIELD_CO_NAMES);
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd9;
                            end
                        end

                        4'd9: begin
                            if (!container_dmem_pending_r) begin
                                names_base_r <= container_rd_data_r;
                                container_dmem_addr_r    <=
                                    PYCORE_ITER_EXHAUST_TYPE_ADDR;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd10;
                            end
                        end

                        4'd10: begin
                            if (!container_dmem_pending_r) begin
                                // Sidecar VAL half of the StopIteration handle.
                                container_val_r <= container_rd_data_r;
                                container_dmem_addr_r    <=
                                    PYCORE_ITER_EXHAUST_TYPE_ADDR + 32'd16;
                                container_dmem_we_r      <= 1'b0;
                                container_dmem_pending_r <= 1'b1;
                                boot_phase_r             <= 4'd11;
                            end
                        end

                        4'd11: begin
                            if (!container_dmem_pending_r) begin
                                iter_exhaust_type_r <= pycore_make_entry(
                                    container_rd_data_r[3:0], container_val_r);
                                redirect_pending_r <= 1'b1;
                                redirect_tgt_r     <= call_entry_slot_r[31:0];
                                boot_phase_r       <= BOOT_PHASE_DONE;
                            end
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
