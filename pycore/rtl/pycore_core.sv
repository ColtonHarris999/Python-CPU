`include "pycore_defs.svh"

// PyCore CPU core: a multi-cycle, non-pipelined machine. Exactly one
// instruction is in flight at a time; a control FSM walks it through
// fetch -> decode -> execute -> memory -> writeback over several cycles and
// only then fetches the next instruction. Because nothing is pipelined there
// is no operand forwarding, no load-use hazard, and no branch flush: the
// register file is always coherent by the time the next instruction reads it.
//
// The core remains a memory master. There is no imem_rdata loopback into the
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
//   S_HALT   : terminal state entered on any trap; the machine freezes.
module pycore_core #(
    parameter int ADDR_WIDTH    = PYCORE_ADDR_WIDTH,
    parameter int IMEM_DATA_W   = PYCORE_IMEM_DATA_WIDTH,
    parameter int DMEM_DATA_W   = PYCORE_DMEM_DATA_WIDTH,
    parameter int CONST_IDX_W   = 8,
    parameter int RF_DEPTH      = 96,
    parameter int STACK_BASE    = 32,
    parameter int STACK_TOP_MAX = 96,
    parameter string STRING_HEX = "pycore/programs/string_mem.hex"
) (
    input  logic                          clk,
    input  logic                          rst_n,
    // imem master
    output logic                          imem_req,
    output logic                          imem_we,
    output logic [ADDR_WIDTH-1:0]         imem_addr,
    output logic [IMEM_DATA_W-1:0]        imem_wdata,
    input  logic                          imem_ack,
    input  logic [IMEM_DATA_W-1:0]        imem_rdata,
    input  logic                          imem_fault,
    // dmem master
    output logic                          dmem_req,
    output logic                          dmem_we,
    output logic [ADDR_WIDTH-1:0]         dmem_addr,
    output logic [DMEM_DATA_W-1:0]        dmem_wdata,
    input  logic                          dmem_ack,
    input  logic [DMEM_DATA_W-1:0]        dmem_rdata,
    input  logic                          dmem_fault,
    // const ROM
    output logic [CONST_IDX_W-1:0]        const_idx,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] const_entry,
    // status
    output logic                          trap_out,
    output logic [3:0]                    trap_code,
    output logic [63:0]                   cycle_count,
    // debug writeback snoop (for verification; mirrors the RF write port)
    output logic                          dbg_wb_we,
    output logic [6:0]                    dbg_wb_addr,
    output logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry
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

    logic [2:0] state;

    // Per-instruction registers.
    logic [7:0]                    cur_opcode;
    logic [31:0]                   cur_arg;
    logic [31:0]                   cur_pc;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs1_q;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs2_q;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_entry_q;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_addr_entry_q;
    logic                          branch_take_q;
    logic [31:0]                   branch_tgt_q;
    logic [PYCORE_ENTRY_WIDTH-1:0] wb_entry_q;
    logic                          wb_we_q;
    logic [6:0]                    tos_q;

    // Fetch handshake bookkeeping.
    logic                          fetch_skip_q;
    logic                          redirect_pending_q;
    logic [31:0]                   redirect_tgt_q;

    // S_CALL management.
    logic                          call_sent_q;   // call_valid was pulsed
    logic                          frame_dmem_pending_q; // frame push or pop in flight

    // One-cycle pulse outputs to frame manager (registered).
    logic                          frame_call_valid_q;
    logic                          frame_return_valid_q;

    // locals_base tracked by the frame module (drives decode).
    logic [RF_AW-1:0]              cur_locals_base;

    // One-cycle RF control pulses for frame transitions.
    logic                          rf_set_locals_q;
    logic [RF_AW-1:0]              rf_new_locals_q;
    logic                          rf_init_frame_q;

    // ---------------------------------------------------------------------
    // IF: instruction fetch
    // ---------------------------------------------------------------------
    logic        if_instr_valid;
    logic [7:0]  if_opcode;
    logic [31:0] if_arg;
    logic [31:0] if_pc;

    logic latch_instr;
    logic fetch_stall;
    assign latch_instr  = (state == S_FETCH) && if_instr_valid && !fetch_skip_q;
    assign fetch_stall  = (state != S_FETCH) || latch_instr;

    pycore_fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(IMEM_DATA_W)
    ) fetch (
        .clk(clk),
        .rst_n(rst_n),
        .stall(fetch_stall),
        .flush(1'b0),
        .branch_taken(redirect_pending_q),
        .branch_target(redirect_tgt_q),
        .imem_req(imem_req),
        .imem_we(imem_we),
        .imem_addr(imem_addr),
        .imem_wdata(imem_wdata),
        .imem_ack(imem_ack),
        .imem_rdata(imem_rdata),
        .instr_valid(if_instr_valid),
        .opcode(if_opcode),
        .arg(if_arg),
        .pc(if_pc)
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
        .instr_valid(1'b1),
        .opcode(cur_opcode),
        .arg(cur_arg),
        .pc(cur_pc),
        .tos_index(tos_q[5:0]),
        .locals_base(cur_locals_base[5:0]),
        .decoded_valid(),
        .alu_op(dec_alu_op),
        .rs1_sel(dec_rs1_sel),
        .rs2_sel(dec_rs2_sel),
        .rd_sel(dec_rd_sel),
        .is_branch(dec_is_branch),
        .is_call(dec_is_call),
        .is_return(dec_is_return),
        .push_stack(dec_push),
        .pop_stack(dec_pop),
        .mem_op(dec_mem_op),
        .illegal_opcode(dec_illegal),
        .decoded_pc(dec_pc)
    );

    // Per-opcode writeback-enable and stack-pointer delta.
    logic              id_rd_we;
    logic signed [2:0] id_tos_delta;
    always_comb begin
        id_rd_we     = 1'b0;
        id_tos_delta = 3'sd0;
        unique case (cur_opcode)
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
    assign is_alu = (cur_opcode == PY_OP_BINARY_OP) || (cur_opcode == PY_OP_COMPARE_OP);

    logic [PYCORE_ENTRY_WIDTH-1:0] exec_result;
    logic                          exec_stall;
    logic                          exec_trap;
    logic [3:0]                    exec_trap_code;

    pycore_exec #(
        .STRING_HEX(STRING_HEX)
    ) exec (
        .clk(clk),
        .rst_n(rst_n),
        .valid((state == S_EXEC) && is_alu),
        .alu_op(dec_alu_op),
        .rs1(rs1_q),
        .rs2(rs2_q),
        .result(exec_result),
        .stall(exec_stall),
        .trap(exec_trap),
        .trap_code(exec_trap_code)
    );

    logic        branch_take;
    logic [31:0] branch_tgt;
    logic        branch_trap;
    logic [3:0]  branch_trap_code;

    pycore_branch branch (
        .opcode(cur_opcode),
        .pc(cur_pc),
        .arg(cur_arg),
        .tos_entry(rs1_q),
        .take_branch(branch_take),
        .branch_target(branch_tgt),
        .trap(branch_trap),
        .trap_code(branch_trap_code)
    );

    logic [PYCORE_ENTRY_WIDTH-1:0] ex_entry;
    logic [PYCORE_ENTRY_WIDTH-1:0] ex_addr_entry;
    always_comb begin
        ex_entry      = rs1_q;
        ex_addr_entry = '0;
        unique case (cur_opcode)
            PY_OP_LOAD_SMALL_INT: ex_entry = pycore_int_entry({32'b0, cur_arg});
            PY_OP_BINARY_OP, PY_OP_COMPARE_OP: ex_entry = exec_result;
            PY_OP_MEM_LOAD_PTR: begin
                ex_entry      = rs1_q;
                ex_addr_entry = rs1_q;
            end
            PY_OP_MEM_STORE_PTR: begin
                ex_entry      = rs1_q;
                ex_addr_entry = rs2_q;
            end
            default: ex_entry = rs1_q;
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
        .DMEM_DATA_W(DMEM_DATA_W),
        .CONST_IDX_W(CONST_IDX_W)
    ) mem_stage (
        .clk(clk),
        .rst_n(rst_n),
        .valid(state == S_MEM),
        .mem_op(dec_mem_op),
        .rd_we_in(id_rd_we),
        .alu_entry(ex_entry_q),
        .addr_entry(ex_addr_entry_q),
        .const_idx(cur_arg[CONST_IDX_W-1:0]),
        .const_entry(const_entry),
        .dmem_req(ms_dmem_req),
        .dmem_we(ms_dmem_we),
        .dmem_addr(ms_dmem_addr),
        .dmem_wdata(ms_dmem_wdata),
        .dmem_ack(dmem_ack),
        .dmem_rdata(dmem_rdata),
        .dmem_fault(dmem_fault),
        .const_idx_out(const_idx),
        .wb_we(mem_wb_we),
        .wb_entry(mem_wb_entry),
        .mem_stall(mem_stall),
        .mem_trap(mem_trap),
        .mem_trap_code(mem_trap_code)
    );

    // ---------------------------------------------------------------------
    // Frame manager (pycore_frame).
    // On CALL the current frame descriptor {pc_return, tos_base, locals_base}
    // is pushed to a DRAM stack in one 128-bit write.  On RETURN it is
    // popped back via a 128-bit read.  The core mediates both dmem
    // transactions through the push/pop handshake.
    // ---------------------------------------------------------------------
    localparam int RF_BASE_CORE        = STACK_BASE;
    localparam int MAX_CALL_DEPTH_CORE = 64;

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
    // dmem_ack fires, keeping pop_data = dmem_rdata valid at that posedge.
    logic frame_push_ack;
    logic frame_pop_ack;
    assign frame_push_ack = (state == S_CALL)   && frame_dmem_pending_q && dmem_ack;
    assign frame_pop_ack  = (state == S_RETURN) && frame_dmem_pending_q && dmem_ack;

    pycore_frame #(
        .RF_DEPTH(RF_DEPTH),
        .RF_BASE(RF_BASE_CORE),
        .MAX_CALL_DEPTH(MAX_CALL_DEPTH_CORE)
    ) frame_mgr (
        .clk(clk),
        .rst_n(rst_n),
        .call_valid(frame_call_valid_q),
        .return_valid(frame_return_valid_q),
        .pc_return_in(cur_pc + 32'd8),
        .tos_base_in(tos_q[RF_AW-1:0]),
        .locals_base_in(cur_locals_base),
        .new_locals_base_in(RF_BASE_CORE[RF_AW-1:0]),
        .pc_return_out(frame_pc_return_out),
        .tos_base_out(frame_tos_base_out),
        .locals_base_out(frame_locals_base_out),
        .next_locals_base(frame_next_locals_base),
        .init_new_frame(frame_init_new_frame),
        .return_done(frame_return_done),
        .active_frames_out(frame_active_depth),
        .head_ptr_out(),
        .tail_ptr_out(),
        .frame_fault(frame_fault_sig),
        .frame_busy(frame_busy),
        .push_req(frame_push_req),
        .push_addr(frame_push_addr),
        .push_data(frame_push_data),
        .push_ack(frame_push_ack),
        .pop_req(frame_pop_req),
        .pop_addr(frame_pop_addr),
        .pop_data(dmem_rdata[DMEM_DATA_W-1:0]),
        .pop_ack(frame_pop_ack)
    );

    // ---------------------------------------------------------------------
    // Register file.  push_stack / pop_stack are left idle.
    // ---------------------------------------------------------------------
    logic rf_we;
    assign rf_we        = (state == S_WB) && wb_we_q && !freeze_pipeline;
    assign dbg_wb_we    = rf_we;
    assign dbg_wb_addr  = dec_rd_sel;
    assign dbg_wb_entry = wb_entry_q;

    pycore_regfile #(
        .RF_DEPTH(RF_DEPTH)
    ) regfile (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr(dec_rs1_sel[RF_AW-1:0]),
        .rs2_addr(dec_rs2_sel[RF_AW-1:0]),
        .rs1(rf_rs1),
        .rs2(rf_rs2),
        .rd_we(rf_we),
        .rd_addr(dec_rd_sel[RF_AW-1:0]),
        .rd(wb_entry_q),
        .set_locals_base(rf_set_locals_q),
        .new_locals_base(rf_new_locals_q),
        .init_frame(rf_init_frame_q),
        .push_stack(1'b0),
        .pop_stack(1'b0),
        .tos_ptr(),
        .locals_base(),
        .stack_fault()
    );

    // ---------------------------------------------------------------------
    // Dmem mux: frame push/pop transactions take priority over mem_stage
    // (which deasserts ms_dmem_req when state != S_MEM — no contention).
    // push: state == S_CALL,   dmem_we = 1
    // pop:  state == S_RETURN, dmem_we = 0
    // ---------------------------------------------------------------------
    logic frame_dmem_active;
    assign frame_dmem_active = frame_dmem_pending_q &&
                               ((state == S_CALL) || (state == S_RETURN));

    assign dmem_req   = frame_dmem_active ? 1'b1          : ms_dmem_req;
    assign dmem_we    = frame_dmem_active ? (state==S_CALL): ms_dmem_we;
    assign dmem_addr  = frame_dmem_active ?
                        ((state == S_CALL) ? frame_push_addr : frame_pop_addr)
                                          : ms_dmem_addr;
    assign dmem_wdata = frame_dmem_active ? frame_push_data : ms_dmem_wdata;

    // ---------------------------------------------------------------------
    // Trap aggregation (single in-flight instruction).
    // ---------------------------------------------------------------------
    logic        freeze_pipeline;
    logic signed [8:0] next_tos;
    assign next_tos = $signed({2'b0, tos_q}) + id_tos_delta;

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
    assign exec_in = (state == S_EXEC);
    assign mem_in  = (state == S_MEM);

    assign type_trap_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_TYPE)) ||
                            (exec_in && dec_is_branch && branch_trap);
    assign stack_fault_sig = (state == S_WB) && !dec_is_call && !dec_is_return &&
                             ((next_tos < STACK_BASE) || (next_tos > STACK_TOP_MAX));
    assign div_zero_sig   = exec_in && exec_trap && (exec_trap_code == PY_TRAP_DIV_ZERO);
    assign fpu_exc_sig    = exec_in && exec_trap && (exec_trap_code == PY_TRAP_FPU_EXCEPTION);
    assign illegal_sig    = (exec_in && dec_illegal) ||
                            (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ILLEGAL_OPCODE));
    assign mem_fault_sig  = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_MEM_FAULT)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_MEM_FAULT)) ||
                            imem_fault;
    assign addr_align_sig = (exec_in && exec_trap && (exec_trap_code == PY_TRAP_ADDR_ALIGN)) ||
                            (mem_in && mem_trap && (mem_trap_code == PY_TRAP_ADDR_ALIGN));
    // Frame faults use the PY_TRAP_CALL_FILTER code (existing placeholder).
    assign frame_fault_trap_sig = (state == S_CALL || state == S_RETURN) &&
                                  frame_fault_sig;

    logic [31:0]                   fault_pc;
    logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs2;
    assign fault_pc  = cur_pc;
    assign fault_rs1 = (state == S_MEM) ? ex_addr_entry_q : rs1_q;
    assign fault_rs2 = (state == S_MEM) ? ex_entry_q : rs2_q;

    pycore_trap trap_block (
        .clk(clk),
        .rst_n(rst_n),
        .type_trap(type_trap_sig),
        .stack_fault(stack_fault_sig),
        .div_zero(div_zero_sig),
        .fpu_exception(fpu_exc_sig),
        .illegal_opcode(illegal_sig || frame_fault_trap_sig),
        .mem_fault(mem_fault_sig),
        .addr_align(addr_align_sig),
        .fault_pc(fault_pc),
        .fault_rs1(fault_rs1),
        .fault_rs2(fault_rs2),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .trap_pc(),
        .trap_rs1(),
        .trap_rs2(),
        .freeze_pipeline(freeze_pipeline)
    );

    // ---------------------------------------------------------------------
    // Control FSM.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_FETCH;
            cur_opcode           <= 8'b0;
            cur_arg              <= 32'b0;
            cur_pc               <= 32'b0;
            rs1_q                <= '0;
            rs2_q                <= '0;
            ex_entry_q           <= '0;
            ex_addr_entry_q      <= '0;
            branch_take_q        <= 1'b0;
            branch_tgt_q         <= 32'b0;
            wb_entry_q           <= '0;
            wb_we_q              <= 1'b0;
            tos_q                <= STACK_BASE[6:0];
            fetch_skip_q         <= 1'b0;
            redirect_pending_q   <= 1'b0;
            redirect_tgt_q       <= 32'b0;
            cycle_count          <= 64'b0;
            cur_locals_base      <= '0;  // base frame locals live in RF[0..31]
            call_sent_q          <= 1'b0;
            frame_dmem_pending_q <= 1'b0;
            frame_call_valid_q   <= 1'b0;
            frame_return_valid_q <= 1'b0;
            rf_set_locals_q      <= 1'b0;
            rf_new_locals_q      <= '0;
            rf_init_frame_q      <= 1'b0;
        end else if (freeze_pipeline) begin
            state <= S_HALT;
        end else begin
            cycle_count          <= cycle_count + 1'b1;

            // Clear one-cycle pulses by default.
            frame_call_valid_q   <= 1'b0;
            frame_return_valid_q <= 1'b0;
            rf_set_locals_q      <= 1'b0;
            rf_init_frame_q      <= 1'b0;

            if (state == S_FETCH) begin
                redirect_pending_q <= 1'b0;
            end

            unique case (state)

                // ----------------------------------------------------------
                S_FETCH: begin
                    if (latch_instr) begin
                        cur_opcode <= if_opcode;
                        cur_arg    <= if_arg;
                        cur_pc     <= if_pc;
                        state      <= S_DECODE;
                    end else if (!if_instr_valid) begin
                        fetch_skip_q <= 1'b0;
                    end
                end

                // ----------------------------------------------------------
                S_DECODE: begin
                    rs1_q <= rf_rs1;
                    rs2_q <= rf_rs2;
                    state <= S_EXEC;
                end

                // ----------------------------------------------------------
                S_EXEC: begin
                    if (!exec_stall) begin
                        ex_entry_q      <= ex_entry;
                        ex_addr_entry_q <= ex_addr_entry;
                        branch_take_q   <= branch_take;
                        branch_tgt_q    <= branch_tgt;
                        state           <= S_MEM;
                    end
                end

                // ----------------------------------------------------------
                S_MEM: begin
                    if (!mem_stall) begin
                        wb_entry_q <= mem_wb_entry;
                        wb_we_q    <= mem_wb_we;
                        state      <= S_WB;
                    end
                end

                // ----------------------------------------------------------
                S_WB: begin
                    if (!dec_is_call && !dec_is_return) begin
                        // Normal instruction writeback.
                        tos_q <= next_tos[6:0];
                        if (dec_is_branch && branch_take_q) begin
                            redirect_pending_q <= 1'b1;
                            redirect_tgt_q     <= branch_tgt_q;
                        end
                        fetch_skip_q <= 1'b1;
                        state        <= S_FETCH;

                    end else if (dec_is_call) begin
                        // CALL: move to frame-management state.
                        call_sent_q          <= 1'b0;
                        frame_dmem_pending_q <= 1'b0;
                        fetch_skip_q         <= 1'b1;
                        state                <= S_CALL;

                    end else begin
                        // RETURN_VALUE.
                        if (frame_active_depth > 0) begin
                            // There is a calling frame: restore caller's PC,
                            // locals_base, and TOS via the frame manager.
                            fetch_skip_q <= 1'b1;
                            state        <= S_RETURN;
                        end else begin
                            // Base-frame return: no caller exists.  Just pop
                            // the TOS and resume fetching.  The program image
                            // ends here; the fetch unit will silently filter the
                            // subsequent CACHE/zero opcodes without trapping.
                            tos_q        <= next_tos[6:0];
                            fetch_skip_q <= 1'b1;
                            state        <= S_FETCH;
                        end
                    end
                end

                // ----------------------------------------------------------
                // S_CALL: push the current frame descriptor to DRAM, then
                // commit the new frame once the write completes.
                //
                //   Cycle 1: pulse call_valid (frame → FS_PUSHING).
                //   Cycle 2: push_req asserted; start one 128-bit dmem write.
                //   Cycle 3: dmem_ack → push_ack (combinational); frame
                //            records the push and fires init_new_frame.
                //   Cycle 4: init_new_frame seen; rotate locals_base, go
                //            to S_FETCH.
                // ----------------------------------------------------------
                S_CALL: begin
                    // Step 1: send call_valid once when frame module is idle.
                    if (!call_sent_q && !frame_busy) begin
                        frame_call_valid_q   <= 1'b1;
                        call_sent_q          <= 1'b1;
                    end

                    // Step 2: when frame asserts push_req, start the dmem write.
                    if (call_sent_q && frame_push_req && !frame_dmem_pending_q) begin
                        frame_dmem_pending_q <= 1'b1;
                    end

                    // Step 3: dmem_ack clears the pending flag; push_ack is
                    // driven combinationally in the same cycle.
                    if (frame_dmem_pending_q && dmem_ack) begin
                        frame_dmem_pending_q <= 1'b0;
                    end

                    // Step 4: push committed — new frame ready.
                    if (frame_init_new_frame) begin
                        cur_locals_base      <= frame_next_locals_base;
                        rf_set_locals_q      <= 1'b1;
                        rf_new_locals_q      <= frame_next_locals_base;
                        rf_init_frame_q      <= 1'b1;
                        call_sent_q          <= 1'b0;
                        frame_dmem_pending_q <= 1'b0;
                        redirect_pending_q   <= 1'b1;
                        redirect_tgt_q       <= cur_pc + 32'd8;
                        state                <= S_FETCH;
                    end
                end

                // ----------------------------------------------------------
                // S_RETURN: pop the previous frame descriptor from DRAM and
                // restore the caller's context.
                //
                //   Cycle 1: pulse return_valid (frame → FS_POPPING).
                //   Cycle 2: pop_req asserted; start one 128-bit dmem read.
                //   Cycle 3: dmem_ack → pop_ack (combinational) with
                //            pop_data = dmem_rdata; frame latches the
                //            restored state and fires return_done.
                //   Cycle 4: return_done seen; read frame outputs and
                //            redirect fetch to the saved return PC.
                // ----------------------------------------------------------
                S_RETURN: begin
                    // Step 1: send return_valid once.
                    if (!call_sent_q && !frame_busy) begin
                        frame_return_valid_q <= 1'b1;
                        call_sent_q          <= 1'b1;
                    end

                    // Step 2: when frame asserts pop_req, start the dmem read.
                    if (call_sent_q && frame_pop_req && !frame_dmem_pending_q) begin
                        frame_dmem_pending_q <= 1'b1;
                    end

                    // Step 3: dmem_ack clears pending; pop_ack is combinational.
                    if (frame_dmem_pending_q && dmem_ack) begin
                        frame_dmem_pending_q <= 1'b0;
                    end

                    // Step 4: frame restored — redirect to saved return PC.
                    // return_done and the frame outputs are valid because they
                    // use the same NBA-visibility window as init_new_frame: the
                    // core reads them before the current cycle's default-clear
                    // NBA can overwrite them (no #1 delay here).
                    if (frame_return_done) begin
                        redirect_pending_q   <= 1'b1;
                        redirect_tgt_q       <= frame_pc_return_out;
                        cur_locals_base      <= frame_locals_base_out;
                        rf_set_locals_q      <= 1'b1;
                        rf_new_locals_q      <= frame_locals_base_out;
                        tos_q                <= frame_tos_base_out;
                        call_sent_q          <= 1'b0;
                        frame_dmem_pending_q <= 1'b0;
                        state                <= S_FETCH;
                    end
                end

                // ----------------------------------------------------------
                S_HALT: begin
                    state <= S_HALT;
                end

                default: begin
                    state <= S_FETCH;
                end
            endcase
        end
    end

endmodule
