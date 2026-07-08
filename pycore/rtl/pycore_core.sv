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
    parameter string STRING_HEX = "pycore/programs/string_mem.hex"
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

    // FSM states.
    localparam logic [2:0] S_FETCH  = 3'd0;
    localparam logic [2:0] S_DECODE = 3'd1;
    localparam logic [2:0] S_EXEC   = 3'd2;
    localparam logic [2:0] S_MEM    = 3'd3;
    localparam logic [2:0] S_WB     = 3'd4;
    localparam logic [2:0] S_HALT   = 3'd5;
    localparam logic [2:0] S_CALL   = 3'd6;
    localparam logic [2:0] S_RETURN = 3'd7;

    logic [2:0] state_r;

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
        .push_stack_o(dec_push),
        .pop_stack_o(dec_pop),
        .mem_op_o(dec_mem_op),
        .illegal_opcode_o(dec_illegal),
        .decoded_pc_o(dec_pc)
    );

    // Per-opcode writeback-enable and stack-pointer delta.
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
            PY_OP_BINARY_OP, PY_OP_COMPARE_OP: begin
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
            default: begin
            end
        endcase
    end

    // Register-file read (asynchronous).
    logic [PYCORE_ENTRY_WIDTH-1:0] rf_rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] rf_rs2;

    // ---------------------------------------------------------------------
    // EX: execute fabric + branch unit
    // ---------------------------------------------------------------------
    logic is_alu;
    assign is_alu = (cur_opcode_r == PY_OP_BINARY_OP) || (cur_opcode_r == PY_OP_COMPARE_OP);

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
    assign rf_we          = ((state_r == S_WB) && wb_we_r && !freeze_pipeline) ||
                            return_wb_we_r;
    assign rf_rd_addr_mux = return_wb_we_r ? return_wb_addr_r  : dec_rd_sel[RF_AW-1:0];
    assign rf_rd_data_mux = return_wb_we_r ? rs1_r             : wb_entry_r;
    assign dbg_wb_we_o    = rf_we;
    assign dbg_wb_addr_o  = {1'b0, rf_rd_addr_mux};
    assign dbg_wb_entry_o = rf_rd_data_mux;

    pycore_regfile #(
        .RF_DEPTH(RF_DEPTH)
    ) regfile (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .rs1_addr_i(dec_rs1_sel[RF_AW-1:0]),
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
    // Dmem mux: frame push/pop transactions take priority over mem_stage
    // (which deasserts ms_dmem_req when state_r != S_MEM — no contention).
    // push: state_r == S_CALL,   dmem_we_o = 1
    // pop:  state_r == S_RETURN, dmem_we_o = 0
    // ---------------------------------------------------------------------
    logic frame_dmem_active;
    assign frame_dmem_active = frame_dmem_pending_r &&
                               ((state_r == S_CALL) || (state_r == S_RETURN));

    assign dmem_req_o   = frame_dmem_active ? 1'b1          : ms_dmem_req;
    assign dmem_we_o    = frame_dmem_active ? (state_r==S_CALL): ms_dmem_we;
    assign dmem_addr_o  = frame_dmem_active ?
                        ((state_r == S_CALL) ? frame_push_addr : frame_pop_addr)
                                          : ms_dmem_addr;
    assign dmem_wdata_o = frame_dmem_active ? frame_push_data : ms_dmem_wdata;

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

    assign type_trap_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_TYPE)) ||
                            (exec_in && dec_is_branch && branch_trap);
    assign stack_fault_sig = (state_r == S_WB) && !dec_is_call && !dec_is_return &&
                             ((next_tos < STACK_BASE) || (next_tos > STACK_TOP_MAX));
    assign div_zero_sig   = exec_in && exec_trap && (exec_trap_code == PY_TRAP_DIV_ZERO);
    assign fpu_exc_sig    = exec_in && exec_trap && (exec_trap_code == PY_TRAP_FPU_EXCEPTION);
    assign illegal_sig    = (exec_in && dec_illegal) ||
                            (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ILLEGAL_OPCODE));
    assign mem_fault_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_MEM_FAULT)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_MEM_FAULT)) ||
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

    // ---------------------------------------------------------------------
    // Control FSM — next-state combinational logic.
    // state_r is the registered current state; state_next is the combinational
    // next state, computed every cycle and sampled on the next rising edge.
    // ---------------------------------------------------------------------
    logic [2:0] state_next;

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
                    if (!exec_stall) state_next = S_MEM;
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
        end else begin
            state_r <= state_next;  // register next state (computed in always_comb)

            cycle_count_o        <= cycle_count_o + 1'b1;

            // Clear one-cycle pulses by default.
            frame_call_valid_r   <= 1'b0;
            frame_return_valid_r <= 1'b0;
            rf_set_locals_r      <= 1'b0;
            rf_init_frame_r      <= 1'b0;
            return_wb_we_r       <= 1'b0;

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
                        // state_next = S_MEM (from always_comb)
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
                S_HALT: ;  // state_next = S_HALT (from always_comb)

                default: ;  // state_next = S_FETCH (from always_comb)

            endcase
        end
    end

endmodule
