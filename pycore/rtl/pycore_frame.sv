`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// pycore_frame: simple call-frame manager for the PyCore CPU.
//
// Design philosophy (PPA-first):
//   Rather than maintaining a complex ring-buffer with per-slot RF
//   residency tracking, this module implements the minimal hardware
//   needed for a correct hardware call stack:
//
//     CALL  →  push current frame descriptor to DRAM, signal core
//     RETURN → pop  previous frame descriptor from DRAM, restore state
//
//   A frame descriptor is exactly one 128-bit DRAM transaction:
//
//     bits [127:96]         pc_return[31:0]
//     bits [127-32 : 127-32-RF_AW+1]  tos_base[RF_AW-1:0]
//     bits [127-32-RF_AW : 127-32-2*RF_AW+1]  locals_base[RF_AW-1:0]
//     remaining bits         zero (reserved)
//
//   The stack grows upward from STACK_BASE_ADDR; sp_r always points to
//   the NEXT free slot.  Stack depth is bounded by MAX_CALL_DEPTH.
//
// FSM:
//   FS_IDLE    – accept call_valid_i or return_valid_i
//   FS_PUSHING – one 128-bit dmem write (CALL path); signals
//                init_new_frame_o on push_ack_i
//   FS_POPPING – one 128-bit dmem read  (RETURN path); signals
//                return_done_o on pop_ack_i, latches restored frame state
//
// Handshake with the core:
//   call_valid_i / return_valid_i – one-cycle pulse, sampled only in FS_IDLE
//   push_req_o / push_addr_o / push_data_o – the core drives dmem_we=1 to
//     push_addr_o with push_data_o; asserts push_ack_i when dmem_ack fires
//   pop_req_o  / pop_addr_o / pop_data_i   – the core drives dmem_we=0 to
//     pop_addr_o; asserts pop_ack_i when dmem_ack fires, with pop_data_i=dmem_rdata
//   frame_busy_o – high while FSM ≠ FS_IDLE; core must not issue a new
//     call_valid_i/return_valid_i during this time
//
// Return-path timing:
//   pc_return_out_o, tos_base_out_o, locals_base_out_o are registered outputs
//   updated from pop_data_i on the posedge that pop_ack_i fires.  They are
//   valid combinationally from the NEXT cycle onward.  The core reads
//   them on the same cycle that return_done_o pulses (the cycle after
//   pop_ack_i) because return_done_o uses the same NBA-visibility window as
//   init_new_frame_o — the core checks for return_done_o without a #1 delay
//   to read the values before the current cycle's default-clear NBA can
//   apply.
module pycore_frame #(
    parameter int MAX_CALL_DEPTH   = 64,
    parameter int RF_DEPTH         = 96,
    parameter int RF_BASE          = 32,
    parameter int ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter logic [ADDR_WIDTH-1:0] STACK_BASE_ADDR  = 32'h0001_0000,
    parameter int STACK_SIZE_BYTES = 32'h0001_0000,
    // Bytes per frame entry (must equal DMEM_DATA_W/8 = 16 for 128-bit dmem).
    parameter int FRAME_ENTRY_BYTES = 16
) (
    input  logic                         clk_i,
    input  logic                         rst_n_i,
    // Call/return control – one-cycle pulses, sampled only in FS_IDLE.
    input  logic                         call_valid_i,
    input  logic                         return_valid_i,
    // Caller context supplied by the core on call_valid_i.
    input  logic [31:0]                  pc_return_in_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  tos_base_in_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  locals_base_in_i,
    // Pass-through: callee locals_base chosen by the core.
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_in_i,
    // Restored caller context (valid from the cycle return_done_o pulses).
    output logic [31:0]                  pc_return_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_base_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  next_locals_base_o,
    // Completion pulses (one cycle each).
    output logic                         init_new_frame_o,   // CALL committed
    output logic                         return_done_o,      // RETURN committed
    // Status.
    output logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out_o,
    output logic [ADDR_WIDTH-1:0]        head_ptr_out_o,
    output logic [ADDR_WIDTH-1:0]        tail_ptr_out_o,
    output logic                         frame_fault_o,
    output logic                         frame_busy_o,
    // Push handshake (CALL): core writes push_data_o to push_addr_o in dmem.
    output logic                         push_req_o,
    output logic [ADDR_WIDTH-1:0]        push_addr_o,
    output logic [PYCORE_DMEM_DATA_WIDTH-1:0] push_data_o,
    input  logic                         push_ack_i,
    // Pop handshake (RETURN): core reads from pop_addr_o; provides pop_data_i.
    output logic                         pop_req_o,
    output logic [ADDR_WIDTH-1:0]        pop_addr_o,
    input  logic [PYCORE_DMEM_DATA_WIDTH-1:0] pop_data_i,
    input  logic                         pop_ack_i
);

    localparam int DEPTH_W = $clog2(MAX_CALL_DEPTH + 1);
    localparam int RF_AW   = $clog2(RF_DEPTH);

    // Frame descriptor bit layout inside the 128-bit dmem word.
    localparam int PC_MSB  = PYCORE_DMEM_DATA_WIDTH - 1;              // 127
    localparam int PC_LSB  = PYCORE_DMEM_DATA_WIDTH - 32;             // 96
    localparam int TOS_MSB = PYCORE_DMEM_DATA_WIDTH - 32 - 1;         // 95
    localparam int TOS_LSB = PYCORE_DMEM_DATA_WIDTH - 32 - RF_AW;     // 89
    localparam int LOC_MSB = PYCORE_DMEM_DATA_WIDTH - 32 - RF_AW - 1; // 88
    localparam int LOC_LSB = PYCORE_DMEM_DATA_WIDTH - 32 - 2*RF_AW;   // 82

    // FSM states.
    localparam logic [1:0] FS_IDLE    = 2'd0;
    localparam logic [1:0] FS_PUSHING = 2'd1;
    localparam logic [1:0] FS_POPPING = 2'd2;

    // Current state (registered) and next state (combinational).
    logic [1:0]            state_r;
    logic [1:0]            state_next;

    logic [DEPTH_W-1:0]   depth_r;
    logic [ADDR_WIDTH-1:0] sp_r;        // next-free stack slot address
    logic [ADDR_WIDTH-1:0] pop_addr_r;  // pop address latched at return_valid_i

    // Restored frame state latched from pop_data_i.
    logic [31:0]          pc_return_r;
    logic [RF_AW-1:0]     tos_base_r;
    logic [RF_AW-1:0]     locals_base_r;

    // One-cycle output pulses.
    logic init_new_frame_r;
    logic return_done_r;
    logic frame_fault_r;

    // --------------------------------------------------------
    // Combinational outputs
    // --------------------------------------------------------
    assign next_locals_base_o  = new_locals_base_in_i;
    assign init_new_frame_o    = init_new_frame_r;
    assign return_done_o       = return_done_r;
    assign frame_fault_o       = frame_fault_r;
    assign frame_busy_o        = (state_r != FS_IDLE);
    assign active_frames_out_o = depth_r;
    assign pc_return_out_o     = pc_return_r;
    assign tos_base_out_o      = tos_base_r;
    assign locals_base_out_o   = locals_base_r;
    assign head_ptr_out_o      = (depth_r > 0) ? STACK_BASE_ADDR : '0;
    assign tail_ptr_out_o      = (depth_r > 0) ?
                               (sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) : '0;

    // Push address is always sp_r (the current next-free slot).
    assign push_req_o  = (state_r == FS_PUSHING);
    assign push_addr_o = sp_r;
    assign push_data_o = {pc_return_in_i,
                        tos_base_in_i,
                        locals_base_in_i,
                        {(PYCORE_DMEM_DATA_WIDTH - 32 - 2*RF_AW){1'b0}}};

    // Pop address is latched before decrementing sp_r.
    assign pop_req_o  = (state_r == FS_POPPING);
    assign pop_addr_o = pop_addr_r;

    // --------------------------------------------------------
    // Next-state combinational logic
    // state_r is the current FSM state; state_next is computed
    // each cycle and registered on the next rising edge.
    // --------------------------------------------------------
    always_comb begin
        state_next = state_r;  // default: stay in current state
        unique case (state_r)
            FS_IDLE: begin
                if (call_valid_i && !return_valid_i &&
                    depth_r < MAX_CALL_DEPTH &&
                    (sp_r + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) <=
                    (STACK_BASE_ADDR + STACK_SIZE_BYTES[ADDR_WIDTH-1:0])) begin
                    state_next = FS_PUSHING;
                end else if (return_valid_i && !call_valid_i && depth_r > 0) begin
                    state_next = FS_POPPING;
                end
                // fault cases: stay in FS_IDLE
            end
            FS_PUSHING: begin
                if (push_ack_i) state_next = FS_IDLE;
            end
            FS_POPPING: begin
                if (pop_ack_i) state_next = FS_IDLE;
            end
            default: state_next = FS_IDLE;
        endcase
    end

    // --------------------------------------------------------
    // Sequential logic: register state_next and update data regs
    // --------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r          <= FS_IDLE;
            depth_r          <= '0;
            sp_r             <= STACK_BASE_ADDR;
            pop_addr_r       <= STACK_BASE_ADDR;
            pc_return_r      <= 32'b0;
            tos_base_r       <= '0;
            locals_base_r    <= '0;
            init_new_frame_r <= 1'b0;
            return_done_r    <= 1'b0;
            frame_fault_r    <= 1'b0;
        end else begin
            state_r <= state_next;

            // Clear one-cycle pulses by default.
            init_new_frame_r <= 1'b0;
            return_done_r    <= 1'b0;
            frame_fault_r    <= 1'b0;

            unique case (state_r)

                // -------------------------------------------------------
                // FS_IDLE: accept call_valid_i or return_valid_i
                // -------------------------------------------------------
                FS_IDLE: begin
                    if (call_valid_i && return_valid_i) begin
                        frame_fault_r <= 1'b1;

                    end else if (call_valid_i) begin
                        if (depth_r >= MAX_CALL_DEPTH) begin
                            frame_fault_r <= 1'b1;
                        end else if ((sp_r + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) >
                                     (STACK_BASE_ADDR +
                                      STACK_SIZE_BYTES[ADDR_WIDTH-1:0])) begin
                            frame_fault_r <= 1'b1;
                        end
                        // state_next already set to FS_PUSHING in always_comb

                    end else if (return_valid_i) begin
                        if (depth_r == 0) begin
                            frame_fault_r <= 1'b1;
                        end else begin
                            pop_addr_r <= sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        end
                        // state_next already set to FS_POPPING in always_comb
                    end
                end

                // -------------------------------------------------------
                // FS_PUSHING: wait for core to complete the dmem write
                // -------------------------------------------------------
                FS_PUSHING: begin
                    if (push_ack_i) begin
                        sp_r             <= sp_r + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        depth_r          <= depth_r + 1'b1;
                        init_new_frame_r <= 1'b1;
                        // state_next = FS_IDLE (from always_comb)
                    end
                end

                // -------------------------------------------------------
                // FS_POPPING: wait for core to complete the dmem read
                // -------------------------------------------------------
                FS_POPPING: begin
                    if (pop_ack_i) begin
                        sp_r          <= sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        depth_r       <= depth_r - 1'b1;
                        pc_return_r   <= pop_data_i[PC_MSB:PC_LSB];
                        tos_base_r    <= pop_data_i[TOS_MSB:TOS_LSB];
                        locals_base_r <= pop_data_i[LOC_MSB:LOC_LSB];
                        return_done_r <= 1'b1;
                        // state_next = FS_IDLE (from always_comb)
                    end
                end

                default: ;  // state_next = FS_IDLE (from always_comb)
            endcase
        end
    end

endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
