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
    parameter int RF_DEPTH      = 96,
    parameter int STACK_BASE    = 32,
    parameter int STACK_TOP_MAX = 96,
    parameter string STRING_HEX = "pycore/programs/string_mem.hex",
    // First free byte of the bump-pointer heap.  A preloaded static heap
    // image sets this above the static objects so runtime allocations do
    // not overwrite them.  Default matches an empty heap.
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE
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
    // status
    output logic                          trap_out_o,
    output logic [3:0]                    trap_code_o,
    output logic [63:0]                   cycle_count_o,
    // debug writeback snoop (for verification; mirrors the RF write port)
    output logic                          dbg_wb_we_o,
    output logic [6:0]                    dbg_wb_addr_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry_o
);

    localparam int RF_AW = $clog2(RF_DEPTH);

    // FSM states (4-bit to accommodate S_CONTAINER).
    localparam logic [3:0] S_FETCH     = 4'd0;
    localparam logic [3:0] S_DECODE    = 4'd1;
    localparam logic [3:0] S_EXEC      = 4'd2;
    localparam logic [3:0] S_MEM       = 4'd3;
    localparam logic [3:0] S_WB        = 4'd4;
    localparam logic [3:0] S_HALT      = 4'd5;
    localparam logic [3:0] S_CALL      = 4'd6;
    localparam logic [3:0] S_RETURN    = 4'd7;
    // S_CONTAINER: multi-cycle handler for BUILD_LIST, BUILD_MAP, BUILD_TUPLE,
    // NB_SUBSCR, and STORE_SUBSCR.  Entered from S_EXEC when dec_is_container
    // is asserted; exits to S_FETCH when done.
    localparam logic [3:0] S_CONTAINER = 4'd8;

    // Container sub-operation codes (stored in container_op_r, 3-bit).
    localparam logic [2:0] CONT_BUILD_LIST   = 3'd0;
    localparam logic [2:0] CONT_SUBSCR_LIST  = 3'd1; // NB_SUBSCR on LIST
    localparam logic [2:0] CONT_STORE_LIST   = 3'd2; // STORE_SUBSCR on LIST
    localparam logic [2:0] CONT_BUILD_MAP    = 3'd3; // BUILD_MAP (dict construction)
    localparam logic [2:0] CONT_SUBSCR_DICT  = 3'd4; // NB_SUBSCR on DICT
    localparam logic [2:0] CONT_STORE_DICT   = 3'd5; // STORE_SUBSCR on DICT
    localparam logic [2:0] CONT_BUILD_TUPLE  = 3'd6; // BUILD_TUPLE
    localparam logic [2:0] CONT_SUBSCR_TUPLE = 3'd7; // NB_SUBSCR on TUPLE

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
    localparam logic [3:0] CP_INIT        = 4'd0;
    localparam logic [3:0] CP_HDR         = 4'd1;
    localparam logic [3:0] CP_VAL         = 4'd2;
    localparam logic [3:0] CP_TAG         = 4'd3;
    localparam logic [3:0] CP_DONE        = 4'd4;
    localparam logic [3:0] CP_DICT_HASH   = 4'd5;
    localparam logic [3:0] CP_DICT_PROBE  = 4'd6;
    localparam logic [3:0] CP_DICT_CHK_VAL= 4'd7;
    localparam logic [3:0] CP_DICT_WR_KVAL= 4'd8;
    localparam logic [3:0] CP_DICT_WR_KTAG= 4'd9;
    localparam logic [3:0] CP_DICT_RD_VAL = 4'd10;
    localparam logic [3:0] CP_DICT_WR_VVAL= 4'd11;
    localparam logic [3:0] CP_DICT_WR_VTAG= 4'd12;
    localparam logic [3:0] CP_DICT_RD_VVAL= 4'd13;
    localparam logic [3:0] CP_DICT_RD_VTAG= 4'd14;

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
    logic [6:0]                    tos_r;

    // CALL arg encoding: arg[15:0] = callee entry slot, arg[31:16] = argc.
    // call_base is the RF slot of the first argument pushed by the caller, which
    // becomes the callee's locals_base AND the slot where S_RETURN places the
    // return value so the caller sees it at TOS after the call completes.
    logic [15:0]      call_target;
    logic [RF_AW-1:0] call_argc_rf;
    logic [RF_AW-1:0] call_base;
    assign call_target   = cur_arg_r[15:0];
    assign call_argc_rf  = cur_arg_r[RF_AW-1+16:16];
    assign call_base     = tos_r[RF_AW-1:0] - call_argc_rf;

    // One-cycle RF write issued from S_RETURN to deposit the callee's return
    // value at call_base on the caller's stack before resuming fetch.
    logic             return_wb_we_r;
    logic [RF_AW-1:0] return_wb_addr_r;

    // Fetch handshake bookkeeping.
    logic                          fetch_skip_r;
    logic                          redirect_pending_r;
    logic [31:0]                   redirect_tgt_r;

    // S_CALL management.
    logic                          call_sent_r;   // call_valid was pulsed
    logic                          frame_dmem_pending_r; // frame push or pop in flight

    // -----------------------------------------------------------------------
    // S_CONTAINER state — heap allocator and container operation registers.
    // -----------------------------------------------------------------------
    // Heap bump allocator.  Starts at PYCORE_HEAP_BASE and grows upward.
    // OOM is detected before each allocation; traps PY_TRAP_MEM_FAULT.
    logic [31:0]                   heap_ptr_r;

    // Which container operation is in flight (CONT_* constants above).
    logic [2:0]                    container_op_r;
    // Which phase within the current operation (CP_* constants above).
    logic [3:0]                    container_phase_r;
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
    logic [PYCORE_ENTRY_WIDTH-1:0] if_inline_const;

    // Inline constant latched alongside the instruction for LOAD_CONST.
    logic [PYCORE_ENTRY_WIDTH-1:0] cur_inline_const_r;

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
        .pc_o(if_pc),
        .inline_const_o(if_inline_const)
    );

    // ---------------------------------------------------------------------
    // ID: decode (pure combinational off the latched instruction + tos).
    // ---------------------------------------------------------------------
    logic [4:0]  dec_alu_op;
    logic [6:0]  dec_rs1_sel;
    logic [6:0]  dec_rs2_sel;
    logic [6:0]  dec_rd_sel;
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
        .tos_index_i(tos_r[5:0]),
        .locals_base_i(cur_locals_base_r[5:0]),
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
            PY_OP_LOAD_FAST, PY_OP_LOAD_FAST_BORROW: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            PY_OP_STORE_FAST: begin
                id_rd_we = 1'b1; id_tos_delta = -3'sd1;
            end
            PY_OP_LOAD_CONST, PY_OP_LOAD_SMALL_INT: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd1;
            end
            PY_OP_BINARY_OP: begin
                // NB_SUBSCR routes to S_CONTAINER; arithmetic ops use S_WB.
                if (dec_is_container) begin
                    id_rd_we = 1'b0; id_tos_delta = 3'sd0;
                end else begin
                    id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
                end
            end
            PY_OP_COMPARE_OP: begin
                id_rd_we = !dec_illegal; id_tos_delta = -3'sd1;
            end
            PY_OP_POP_TOP, PY_OP_POP_ITER: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_RETURN_VALUE: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_POP_JUMP_IF_TRUE, PY_OP_POP_JUMP_IF_FALSE: begin
                id_tos_delta = -3'sd1;
            end
            PY_OP_MEM_LOAD_PTR: begin
                id_rd_we = 1'b1; id_tos_delta = 3'sd0;
            end
            PY_OP_MEM_STORE_PTR: begin
                id_tos_delta = -3'sd2;
            end
            // Container ops: TOS managed by S_CONTAINER, not S_WB.
            PY_OP_BUILD_LIST, PY_OP_BUILD_MAP, PY_OP_BUILD_TUPLE, PY_OP_STORE_SUBSCR: begin
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
    assign rs1_addr_eff = (state_r == S_CONTAINER) ? container_rf_addr_r
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
        ex_entry      = rs1_r;
        ex_addr_entry = '0;
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
        .inline_const_i(cur_inline_const_r),
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
    // On CALL the current frame descriptor {pc_return, tos_base, locals_base}
    // is pushed to a DRAM stack in one 128-bit write.  On RETURN it is
    // popped back via a 128-bit read.  The core mediates both dmem
    // transactions through the push/pop handshake.
    //
    // The frame stack lives in the upper half of the 16 KB data memory
    // (byte addresses 0x2000–0x3FFF), leaving the lower 8 KB for user-level
    // pointer data.  STACK_BASE_ADDR must be within the dmem address window
    // (BLOCK_COUNT × 2^BLOCK_SHIFT = 4 × 4 KB = 16 KB).
    // ---------------------------------------------------------------------
    localparam int    RF_BASE_CORE          = STACK_BASE;
    localparam int    MAX_CALL_DEPTH_CORE   = 64;
    localparam logic [ADDR_WIDTH-1:0] FRAME_STACK_BASE = 32'h0000_2000;
    localparam int    FRAME_STACK_BYTES     = 32'h0000_2000;  // 8 KB, 512 frames

    logic [RF_AW-1:0]      frame_next_locals_base;
    logic                  frame_init_new_frame;
    logic                  frame_return_done;
    logic                  frame_fault_sig;
    logic                  frame_busy;
    logic [31:0]           frame_pc_return_out;
    logic [RF_AW-1:0]      frame_tos_base_out;
    logic [RF_AW-1:0]      frame_locals_base_out;
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
        .pc_return_in_i(cur_pc_r + 32'd1),
        .tos_base_in_i(call_base),
        .locals_base_in_i(cur_locals_base_r),
        .new_locals_base_in_i(call_base),
        .pc_return_out_o(frame_pc_return_out),
        .tos_base_out_o(frame_tos_base_out),
        .locals_base_out_o(frame_locals_base_out),
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
    assign dbg_wb_addr_o  = {1'b0, rf_rd_addr_mux};
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
    //   2. container_dmem_active (S_CONTAINER): heap alloc / element R/W.
    //   3. ms_dmem_* (S_MEM): normal PTR load/store.
    // Sources 1 and 2 are mutually exclusive (different FSM states); source 3
    // is only active when state_r == S_MEM, which never overlaps with 1 or 2.
    // ---------------------------------------------------------------------
    logic frame_dmem_active;
    logic container_dmem_active;
    assign frame_dmem_active     = frame_dmem_pending_r &&
                                   ((state_r == S_CALL) || (state_r == S_RETURN));
    assign container_dmem_active = container_dmem_pending_r && (state_r == S_CONTAINER);

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
    logic signed [8:0] next_tos;
    assign next_tos = $signed({2'b0, tos_r}) + id_tos_delta;

    logic type_trap_sig;
    logic stack_fault_sig;
    logic div_zero_sig;
    logic fpu_exc_sig;
    logic illegal_sig;
    logic mem_fault_sig;
    logic addr_align_sig;
    logic frame_fault_trap_sig;

    logic exec_in;
    logic mem_in;
    assign exec_in = (state_r == S_EXEC);
    assign mem_in  = (state_r == S_MEM);

    // container_type_trap_r / container_mem_fault_r are one-cycle pulses set in
    // S_CONTAINER's always_ff when a type or bounds error is detected.
    assign type_trap_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_TYPE)) ||
                            (exec_in && dec_is_branch && branch_trap) ||
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
                            container_mem_fault_r ||
                            imem_fault_i;
    assign addr_align_sig = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ADDR_ALIGN)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_ADDR_ALIGN));
    // Frame faults use the PY_TRAP_CALL_FILTER code (existing placeholder).
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
        .illegal_opcode_i(illegal_sig || frame_fault_trap_sig),
        .mem_fault_i(mem_fault_sig),
        .addr_align_i(addr_align_sig),
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
    logic [31:0]  cont_bl_alloc;  // bytes to allocate for BUILD_LIST
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
    assign cont_bl_alloc  = pycore_list_alloc_bytes({25'b0, container_count_r});
    assign cont_bt_alloc  = pycore_tuple_alloc_bytes({25'b0, container_count_r});
    assign cont_tuple_size = pycore_tuple_size(cont_rs1_val);
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
    // SHORT_STR / LONG_STR: full 128-bit value-field equality.
    // LONG_STR equality relies on interning: the tooling guarantees at most
    // one copy of each distinct long string in the image, so descriptor
    // equality is string equality. Runtime-concatenated LONG_STR results
    // (private to pycore_exec string_mem, not interned) are NOT valid dict
    // keys semantically; hardware cannot detect this (known limitation).
    logic cont_dict_key_match;
    assign cont_dict_key_match =
        (container_tag_r == PY_TAG_INT)  ? (container_rd_data_r[63:0] == container_val_r[63:0]) :
        (container_tag_r == PY_TAG_BOOL) ? (container_rd_data_r[0]    == container_val_r[0])    :
        (container_tag_r == PY_TAG_SHORT_STR ||
         container_tag_r == PY_TAG_LONG_STR) ? (container_rd_data_r == container_val_r) :
        1'b0;

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
                    if (frame_init_new_frame) state_next = S_FETCH;
                end
                S_RETURN: begin
                    if (frame_return_done) state_next = S_FETCH;
                end
                S_CONTAINER: begin
                    // CP_DONE is a terminal marker phase used uniformly by all
                    // sub-operations.  All actual work (RF write, TOS update) is
                    // committed in the cycle that advances container_phase_r to
                    // CP_DONE, so the CP_DONE always_ff case is intentionally empty.
                    // Once container_phase_r == CP_DONE the FSM transitions to
                    // S_FETCH.
                    if (container_phase_r == CP_DONE) state_next = S_FETCH;
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
            state_r                <= S_FETCH;
            cur_opcode_r           <= 8'b0;
            cur_arg_r              <= 32'b0;
            cur_pc_r               <= 32'b0;
            cur_inline_const_r     <= '0;
            rs1_r                <= '0;
            rs2_r                <= '0;
            ex_entry_r           <= '0;
            ex_addr_entry_r      <= '0;
            branch_take_r        <= 1'b0;
            branch_tgt_r         <= 32'b0;
            wb_entry_r           <= '0;
            wb_we_r              <= 1'b0;
            tos_r                <= STACK_BASE[6:0];
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
            container_dmem_pending_r <= 1'b0;
            container_dmem_addr_r    <= '0;
            container_dmem_we_r      <= 1'b0;
            container_dmem_wdata_r   <= '0;
            container_wb_we_r        <= 1'b0;
            container_wb_addr_r      <= '0;
            container_wb_data_r      <= '0;
            container_type_trap_r    <= 1'b0;
            container_mem_fault_r    <= 1'b0;
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
                        cur_inline_const_r <= if_inline_const;
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

                            if (cur_opcode_r == PY_OP_BUILD_LIST) begin
                                container_op_r    <= CONT_BUILD_LIST;
                                container_count_r <= cur_arg_r[6:0];
                                container_idx_r   <= 7'd0;
                            end else if (cur_opcode_r == PY_OP_BUILD_MAP) begin
                                container_op_r    <= CONT_BUILD_MAP;
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
                            end else begin
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
                        tos_r <= next_tos[6:0];
                        if (dec_is_branch && branch_take_r) begin
                            redirect_pending_r <= 1'b1;
                            redirect_tgt_r     <= branch_tgt_r;
                        end
                        fetch_skip_r <= 1'b1;
                        // state_next = S_FETCH (from always_comb)

                    end else if (dec_is_call) begin
                        // CALL: move to frame-management state.
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        fetch_skip_r         <= 1'b1;
                        // state_next = S_CALL (from always_comb)

                    end else begin
                        // RETURN_VALUE.
                        if (frame_active_depth > 0) begin
                            // There is a calling frame: restore caller's PC,
                            // locals_base, and TOS via the frame manager.
                            fetch_skip_r <= 1'b1;
                            // state_next = S_RETURN (from always_comb)
                        end else begin
                            // Base-frame return: no caller exists.  Just pop
                            // the TOS and resume fetching.
                            tos_r        <= next_tos[6:0];
                            fetch_skip_r <= 1'b1;
                            // state_next = S_FETCH (from always_comb)
                        end
                    end
                end

                // ----------------------------------------------------------
                // S_CALL: push the current frame descriptor to DRAM, then
                // commit the new frame once the write completes.
                //
                //   Cycle 1: pulse call_valid (frame → FS_PUSHING).
                //   Cycle 2: push_req_o asserted; start one 128-bit dmem write.
                //   Cycle 3: dmem_ack_i → push_ack (combinational); frame
                //            records the push and fires init_new_frame_o.
                //   Cycle 4: init_new_frame_o seen; rotate locals_base, go
                //            to S_FETCH. (state_next = S_FETCH from always_comb)
                // ----------------------------------------------------------
                S_CALL: begin
                    // Step 1: send call_valid once when frame module is idle.
                    if (!call_sent_r && !frame_busy) begin
                        frame_call_valid_r   <= 1'b1;
                        call_sent_r          <= 1'b1;
                    end

                    // Step 2: when frame asserts push_req_o, start the dmem write.
                    if (call_sent_r && frame_push_req && !frame_dmem_pending_r) begin
                        frame_dmem_pending_r <= 1'b1;
                    end

                    // Step 3: dmem_ack_i clears the pending flag; push_ack is
                    // driven combinationally in the same cycle.
                    if (frame_dmem_pending_r && dmem_ack_i) begin
                        frame_dmem_pending_r <= 1'b0;
                    end

                    // Step 4: push committed — new frame ready.
                    if (frame_init_new_frame) begin
                        cur_locals_base_r    <= frame_next_locals_base;
                        rf_set_locals_r      <= 1'b1;
                        rf_new_locals_r      <= frame_next_locals_base;
                        // Only zero-init the callee's locals when no arguments
                        // were passed; arguments already live in RF[call_base..]
                        // and rf_init_frame would overwrite them.
                        rf_init_frame_r      <= (call_argc_rf == '0);
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        redirect_pending_r   <= 1'b1;
                        redirect_tgt_r       <= {16'b0, call_target};
                        // state_next = S_FETCH (from always_comb)
                    end
                end

                // ----------------------------------------------------------
                // S_RETURN: pop the previous frame descriptor from DRAM and
                // restore the caller's context.
                //
                //   Cycle 1: pulse return_valid (frame → FS_POPPING).
                //   Cycle 2: pop_req_o asserted; start one 128-bit dmem read.
                //   Cycle 3: dmem_ack_i → pop_ack (combinational) with
                //            pop_data_i = dmem_rdata_i; frame latches the
                //            restored state and fires return_done_o.
                //   Cycle 4: return_done_o seen; redirect fetch to saved PC.
                //            (state_next = S_FETCH from always_comb)
                // ----------------------------------------------------------
                S_RETURN: begin
                    // Step 1: send return_valid once.
                    if (!call_sent_r && !frame_busy) begin
                        frame_return_valid_r <= 1'b1;
                        call_sent_r          <= 1'b1;
                    end

                    // Step 2: when frame asserts pop_req_o, start the dmem read.
                    if (call_sent_r && frame_pop_req && !frame_dmem_pending_r) begin
                        frame_dmem_pending_r <= 1'b1;
                    end

                    // Step 3: dmem_ack_i clears pending; pop_ack is combinational.
                    if (frame_dmem_pending_r && dmem_ack_i) begin
                        frame_dmem_pending_r <= 1'b0;
                    end

                    // Step 4: frame restored — redirect to saved return PC.
                    // return_done_o and the frame outputs are valid in the same
                    // NBA-visibility window as init_new_frame_o.
                    if (frame_return_done) begin
                        redirect_pending_r   <= 1'b1;
                        redirect_tgt_r       <= frame_pc_return_out;
                        cur_locals_base_r    <= frame_locals_base_out;
                        rf_set_locals_r      <= 1'b1;
                        rf_new_locals_r      <= frame_locals_base_out;
                        // Place the callee's return value at call_base on the
                        // caller's stack. The actual RF write fires next cycle.
                        return_wb_we_r       <= 1'b1;
                        return_wb_addr_r     <= frame_tos_base_out;
                        tos_r                <= frame_tos_base_out + 7'd1;
                        call_sent_r          <= 1'b0;
                        frame_dmem_pending_r <= 1'b0;
                        // state_next = S_FETCH (from always_comb)
                    end
                end

                // ----------------------------------------------------------
                // S_CONTAINER: multi-cycle handler for container operations.
                //
                // Sub-phases (container_phase_r):
                //
                //   BUILD_LIST(count):
                //     CP_INIT : write header {count, count} to heap; set RF addr.
                //     CP_HDR  : ack of header write → empty-list early exit, or
                //               save RF data and write value.
                //     CP_VAL  : ack of value write  → write tag.
                //     CP_TAG  : ack of tag write    → idx++; loop or CP_DONE.
                //     CP_DONE : terminal marker; always_comb → S_FETCH.
                //
                //   BINARY_OP / NB_SUBSCR (list read):
                //     CP_INIT : check types; start header read.
                //     CP_HDR  : ack header  → bounds check; start value read.
                //     CP_VAL  : ack value   → save value; start tag read.
                //     CP_TAG  : ack tag     → assemble result; pulse wb/TOS/done.
                //
                //   STORE_SUBSCR (list write):
                //     CP_INIT : check types; set RF addr for value; start header read.
                //     CP_HDR  : ack header  → read RF value; bounds check; write value.
                //     CP_VAL  : ack value   → write tag.
                //     CP_TAG  : ack tag     → update TOS, go to S_FETCH.
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

                                // Phase 0 (CP_INIT): check OOM and issue
                                // header write.
                                CP_INIT: begin
                                    // OOM check: ensure heap has room for
                                    // 1 header + 2*count element slots.
                                    if ((heap_ptr_r + cont_bl_alloc) > PYCORE_HEAP_LIMIT) begin
                                        container_mem_fault_r <= 1'b1;
                                    end else begin
                                        // Allocate list base.
                                        container_base_r       <= heap_ptr_r;
                                        // Issue header write: {capacity, length}.
                                        container_dmem_addr_r  <= heap_ptr_r;
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= pycore_list_header(
                                            {57'b0, container_count_r},
                                            {57'b0, container_count_r});
                                        container_dmem_pending_r <= 1'b1;
                                        heap_ptr_r             <= heap_ptr_r + 32'd16;
                                        // Pre-load RF address for element 0.
                                        container_rf_addr_r <= RF_AW'(
                                            {2'b0, tos_r} - {2'b0, container_count_r});
                                        container_idx_r        <= 7'd0;
                                        container_phase_r      <= CP_HDR;
                                    end
                                end

                                // Phase 1 (CP_HDR): wait for header-write ack.
                                // Empty list: commit handle now (do not advance
                                // heap_ptr beyond the 16-byte header).
                                // Non-empty: RF address set last cycle; rf_rs1 valid.
                                CP_HDR: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_count_r == 7'd0) begin
                                            // Empty list: header only.
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_LIST,
                                                {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Save element from RF (async read valid now).
                                            container_tag_r        <= cont_rf_rs1_tag;
                                            container_val_r        <= cont_rf_rs1_val;
                                            // Issue element value write.
                                            container_dmem_addr_r  <= pycore_list_val_addr(
                                                container_base_r,
                                                {25'b0, container_idx_r});
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= cont_rf_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            heap_ptr_r             <= heap_ptr_r + 32'd16;
                                            container_phase_r      <= CP_VAL;
                                        end
                                    end
                                end

                                // Phase 2 (CP_VAL): wait for element value-write ack.
                                CP_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        // Issue element tag write.
                                        container_dmem_addr_r  <= pycore_list_tag_addr(
                                            container_base_r,
                                            {25'b0, container_idx_r});
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        heap_ptr_r             <= heap_ptr_r + 32'd16;
                                        container_phase_r      <= CP_TAG;
                                    end
                                end

                                // Phase 3 (CP_TAG): wait for element tag-write ack.
                                // When all elements are written, commit the list
                                // handle here (in the same ack cycle) and advance
                                // to CP_DONE, which is an intentionally empty
                                // terminal phase that triggers S_FETCH transition.
                                CP_TAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_idx_r + 7'd1 < container_count_r) begin
                                            // More elements: advance to next.
                                            container_idx_r     <= container_idx_r + 7'd1;
                                            container_rf_addr_r <= RF_AW'(
                                                {2'b0, tos_r}
                                                - {2'b0, container_count_r}
                                                + {2'b0, container_idx_r}
                                                + 9'd1);
                                            container_phase_r   <= CP_HDR;
                                        end else begin
                                            // All elements written — commit list.
                                            // Push {PY_TAG_LIST, 0, base} to RF[tos-count].
                                            // heap_ptr advanced by exactly
                                            // pycore_list_alloc_bytes(count).
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

                                // Phase 4 (CP_DONE): terminal marker — do nothing.
                                // All commit work was done in CP_TAG / empty CP_HDR.
                                // The always_comb state-next logic transitions to
                                // S_FETCH the same cycle container_phase_r=CP_DONE.
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
                                        // Issue header read.
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
                                            // Read element value.
                                            container_dmem_addr_r <= pycore_list_val_addr(
                                                container_base_r, cont_key_u[31:0]);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r        <= CP_VAL;
                                        end
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
                                        container_wb_addr_r <= RF_AW'(tos_r - 7'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        // Pop 1 (key): tos-2 keeps the result.
                                        tos_r             <= tos_r - 7'd1;
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
                                        container_rf_addr_r      <= RF_AW'(tos_r - 7'd3);
                                        // Start header read.
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
                                            // Save value from RF.
                                            container_tag_r        <= cont_rf_rs1_tag;
                                            container_val_r        <= cont_rf_rs1_val;
                                            // Write value slot.
                                            container_dmem_addr_r  <= pycore_list_val_addr(
                                                container_base_r, cont_key_u_st[31:0]);
                                            container_dmem_we_r    <= 1'b1;
                                            container_dmem_wdata_r <= cont_rf_rs1_val;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r      <= CP_VAL;
                                        end
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
                                        tos_r             <= tos_r - 7'd3;
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                // CP_DONE: terminal — nothing to execute.
                                CP_DONE: ;

                                default: ;

                            endcase
                        end // CONT_STORE_LIST

                        // ===========================================================
                        // CONT_BUILD_MAP: allocate dict + linear-probe insert all pairs.
                        // Tracks `used` in container_used_r and rewrites the header
                        // once at the end. Probe loops are bounded by slot_count.
                        // ===========================================================
                        CONT_BUILD_MAP: begin
                            unique case (container_phase_r)

                                // Phase 0: OOM check, allocate header.
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

                                // Phase 1: wait for header write ack.
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
                                        end else if (container_count_r == 7'd0) begin
                                            // Empty dict: done (used already 0).
                                            container_wb_we_r   <= 1'b1;
                                            container_wb_addr_r <= RF_AW'({2'b0, tos_r});
                                            container_wb_data_r <= pycore_make_entry(
                                                PY_TAG_DICT, {{96{1'b0}}, container_base_r});
                                            tos_r             <= tos_r + 7'd1;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            // Read first pair's key from RF.
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
                                                    container_probe_r  <= probe0;
                                                    container_probe_n_r <= 32'd0;
                                                    container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                        container_base_r, probe0);
                                                end
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_PROBE;
                                            end
                                        end
                                    end
                                end

                                // Probe: wait for ktag read; check empty/match/collision.
                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Empty slot → insert here (new key).
                                                container_insert_new_r <= 1'b1;
                                                container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                    container_base_r, container_probe_r);
                                                container_dmem_we_r    <= 1'b1;
                                                container_dmem_wdata_r <= container_val_r;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_WR_KVAL;
                                            end else if (container_rd_data_r[3:0] == container_tag_r) begin
                                                container_dmem_addr_r <= pycore_dict_kval_addr(
                                                    container_base_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end else if (container_probe_n_r + 32'd1
                                                         >= container_slot_count_r) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                container_probe_r <= cont_probe_next;
                                                container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                    container_base_r, cont_probe_next);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            // Same key: overwrite (do not bump used).
                                            container_insert_new_r <= 1'b0;
                                            container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                container_base_r, container_probe_r);
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
                                                container_base_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_base_r, container_probe_r);
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
                                        container_base_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_base_r, container_probe_r);
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
                                            // All pairs inserted — rewrite header with used.
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
                                            container_base_r, cont_dict_hash);
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
                        // rs1_r = dict handle; rs2_r = key (INT/BOOL/SHORT_STR/LONG_STR).
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
                                        begin
                                            logic [31:0] probe0;
                                            probe0 = pycore_dict_key_hash(
                                                container_tag_r, container_val_r)
                                                & (cont_dict_hdr_slots[31:0] - 32'd1);
                                            container_probe_r   <= probe0;
                                            container_probe_n_r <= 32'd0;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_base_r, probe0);
                                        end
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_PROBE;
                                    end
                                end

                                CP_DICT_PROBE: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_probe_n_r >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_n_r <= container_probe_n_r + 32'd1;
                                            if (container_rd_data_r[3:0] == PY_TAG_UNINIT) begin
                                                // Key not found.
                                                container_mem_fault_r <= 1'b1;
                                            end else if (container_rd_data_r[3:0] == container_tag_r) begin
                                                container_dmem_addr_r <= pycore_dict_kval_addr(
                                                    container_base_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end else if (container_probe_n_r + 32'd1
                                                         >= container_slot_count_r) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                container_probe_r <= cont_probe_next;
                                                container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                    container_base_r, cont_probe_next);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                            end
                                        end
                                    end
                                end

                                CP_DICT_CHK_VAL: begin
                                    if (!container_dmem_pending_r) begin
                                        if (cont_dict_key_match) begin
                                            container_dmem_addr_r <= pycore_dict_vval_addr(
                                                container_base_r, container_probe_r);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_RD_VVAL;
                                        end else if (container_probe_n_r
                                                     >= container_slot_count_r) begin
                                            container_mem_fault_r <= 1'b1;
                                        end else begin
                                            container_probe_r <= cont_probe_next;
                                            container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                container_base_r, cont_probe_next);
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
                                            container_base_r, container_probe_r);
                                        container_dmem_we_r      <= 1'b0;
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_RD_VTAG;
                                    end
                                end

                                CP_DICT_RD_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        container_wb_we_r   <= 1'b1;
                                        container_wb_addr_r <= RF_AW'(tos_r - 7'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0], container_val_r);
                                        tos_r             <= tos_r - 7'd1;
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_DICT

                        // ===========================================================
                        // CONT_STORE_DICT: dict key upsert (STORE_SUBSCR on DICT handle).
                        // rs1_r = key; rs2_r = dict handle; value = RF[tos-3].
                        // Interim policy: never fill the table completely — require
                        // used + 1 < slot_count before an empty-slot insert so at
                        // least one empty slot always remains.
                        // ===========================================================
                        CONT_STORE_DICT: begin
                            unique case (container_phase_r)

                                CP_INIT: begin
                                    if (!pycore_dict_key_tag_ok(cont_rs1_tag)) begin
                                        container_type_trap_r <= 1'b1;
                                    end else begin
                                        container_tag_r <= cont_rs1_tag;
                                        container_val_r <= cont_rs1_val;
                                        container_rf_addr_r     <= RF_AW'(tos_r - 7'd3);
                                        container_val_rf_addr_r <= RF_AW'(tos_r - 7'd3);
                                        container_insert_new_r  <= 1'b0;
                                        container_finishing_r   <= 1'b0;
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
                                            // used-count header rewrite acked → pop and done.
                                            container_finishing_r <= 1'b0;
                                            tos_r             <= tos_r - 7'd3;
                                            fetch_skip_r      <= 1'b1;
                                            container_phase_r <= CP_DONE;
                                        end else begin
                                            container_slot_count_r <= cont_dict_hdr_slots[31:0];
                                            container_used_r       <= cont_dict_hdr_used;
                                            begin
                                                logic [31:0] probe0;
                                                probe0 = pycore_dict_key_hash(
                                                    container_tag_r, container_val_r)
                                                    & (cont_dict_hdr_slots[31:0] - 32'd1);
                                                container_probe_r   <= probe0;
                                                container_probe_n_r <= 32'd0;
                                                container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                    container_base_r, probe0);
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
                                                // Empty slot → insert iff room remains
                                                // for at least one empty after insert.
                                                if (!(container_used_r + 64'd1
                                                        < {32'b0, container_slot_count_r})) begin
                                                    container_mem_fault_r <= 1'b1;
                                                end else begin
                                                    container_insert_new_r <= 1'b1;
                                                    container_dmem_addr_r  <= pycore_dict_kval_addr(
                                                        container_base_r, container_probe_r);
                                                    container_dmem_we_r    <= 1'b1;
                                                    container_dmem_wdata_r <= container_val_r;
                                                    container_dmem_pending_r <= 1'b1;
                                                    container_phase_r <= CP_DICT_WR_KVAL;
                                                end
                                            end else if (container_rd_data_r[3:0] == container_tag_r) begin
                                                container_dmem_addr_r <= pycore_dict_kval_addr(
                                                    container_base_r, container_probe_r);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
                                                container_phase_r <= CP_DICT_CHK_VAL;
                                            end else if (container_probe_n_r + 32'd1
                                                         >= container_slot_count_r) begin
                                                container_mem_fault_r <= 1'b1;
                                            end else begin
                                                container_probe_r <= cont_probe_next;
                                                container_dmem_addr_r <= pycore_dict_ktag_addr(
                                                    container_base_r, cont_probe_next);
                                                container_dmem_we_r      <= 1'b0;
                                                container_dmem_pending_r <= 1'b1;
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
                                                container_base_r, container_probe_r);
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
                                                container_base_r, cont_probe_next);
                                            container_dmem_we_r      <= 1'b0;
                                            container_dmem_pending_r <= 1'b1;
                                            container_phase_r <= CP_DICT_PROBE;
                                        end
                                    end
                                end

                                CP_DICT_WR_KVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_ktag_addr(
                                            container_base_r, container_probe_r);
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
                                        container_base_r, container_probe_r);
                                    container_dmem_we_r    <= 1'b1;
                                    container_dmem_wdata_r <= cont_rf_rs1_val;
                                    container_dmem_pending_r <= 1'b1;
                                    container_phase_r <= CP_DICT_WR_VVAL;
                                end

                                CP_DICT_WR_VVAL: begin
                                    if (!container_dmem_pending_r) begin
                                        container_dmem_addr_r  <= pycore_dict_vtag_addr(
                                            container_base_r, container_probe_r);
                                        container_dmem_we_r    <= 1'b1;
                                        container_dmem_wdata_r <= {124'b0, container_tag_r};
                                        container_dmem_pending_r <= 1'b1;
                                        container_phase_r <= CP_DICT_WR_VTAG;
                                    end
                                end

                                CP_DICT_WR_VTAG: begin
                                    if (!container_dmem_pending_r) begin
                                        if (container_insert_new_r) begin
                                            // Bump used in header before completing.
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
                                            tos_r             <= tos_r - 7'd3;
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
                                        tos_r             <= tos_r + 7'd1;
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
                                        container_wb_addr_r <= RF_AW'(tos_r - 7'd2);
                                        container_wb_data_r <= pycore_make_entry(
                                            container_rd_data_r[3:0],
                                            container_val_r);
                                        tos_r             <= tos_r - 7'd1;
                                        fetch_skip_r      <= 1'b1;
                                        container_phase_r <= CP_DONE;
                                    end
                                end

                                CP_DONE: ;
                                default: ;

                            endcase
                        end // CONT_SUBSCR_TUPLE


                        default: ;

                    endcase
                end // S_CONTAINER

                // ----------------------------------------------------------
                S_HALT: ;  // state_next = S_HALT (from always_comb)

                default: ;  // state_next = S_FETCH (from always_comb)

            endcase
        end
    end

endmodule
