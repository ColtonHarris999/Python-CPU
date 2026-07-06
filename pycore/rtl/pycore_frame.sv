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
//   The stack grows upward from STACK_BASE_ADDR; sp_q always points to
//   the NEXT free slot.  Stack depth is bounded by MAX_CALL_DEPTH.
//
// FSM:
//   FS_IDLE    – accept call_valid or return_valid
//   FS_PUSHING – one 128-bit dmem write (CALL path); signals
//                init_new_frame on push_ack
//   FS_POPPING – one 128-bit dmem read  (RETURN path); signals
//                return_done on pop_ack, latches restored frame state
//
// Handshake with the core:
//   call_valid / return_valid – one-cycle pulse, sampled only in FS_IDLE
//   push_req / push_addr / push_data – the core drives dmem_we=1 to
//     push_addr with push_data; asserts push_ack when dmem_ack fires
//   pop_req  / pop_addr / pop_data   – the core drives dmem_we=0 to
//     pop_addr; asserts pop_ack when dmem_ack fires, with pop_data=dmem_rdata
//   frame_busy – high while FSM ≠ FS_IDLE; core must not issue a new
//     call_valid/return_valid during this time
//
// Return-path timing:
//   pc_return_out, tos_base_out, locals_base_out are registered outputs
//   updated from pop_data on the posedge that pop_ack fires.  They are
//   valid combinationally from the NEXT cycle onward.  The core reads
//   them on the same cycle that return_done pulses (the cycle after
//   pop_ack) because return_done uses the same NBA-visibility window as
//   init_new_frame — the core checks for return_done without a #1 delay
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
    input  logic                         clk,
    input  logic                         rst_n,
    // Call/return control – one-cycle pulses, sampled only in FS_IDLE.
    input  logic                         call_valid,
    input  logic                         return_valid,
    // Caller context supplied by the core on call_valid.
    input  logic [31:0]                  pc_return_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  tos_base_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  locals_base_in,
    // Pass-through: callee locals_base chosen by the core.
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_in,
    // Restored caller context (valid from the cycle return_done pulses).
    output logic [31:0]                  pc_return_out,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  next_locals_base,
    // Completion pulses (one cycle each).
    output logic                         init_new_frame,   // CALL committed
    output logic                         return_done,      // RETURN committed
    // Status.
    output logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out,
    output logic [ADDR_WIDTH-1:0]        head_ptr_out,
    output logic [ADDR_WIDTH-1:0]        tail_ptr_out,
    output logic                         frame_fault,
    output logic                         frame_busy,
    // Push handshake (CALL): core writes push_data to push_addr in dmem.
    output logic                         push_req,
    output logic [ADDR_WIDTH-1:0]        push_addr,
    output logic [PYCORE_DMEM_DATA_WIDTH-1:0] push_data,
    input  logic                         push_ack,
    // Pop handshake (RETURN): core reads from pop_addr; provides pop_data.
    output logic                         pop_req,
    output logic [ADDR_WIDTH-1:0]        pop_addr,
    input  logic [PYCORE_DMEM_DATA_WIDTH-1:0] pop_data,
    input  logic                         pop_ack
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

    logic [1:0]           ffsm_q;
    logic [DEPTH_W-1:0]   depth_q;
    logic [ADDR_WIDTH-1:0] sp_q;        // next-free stack slot address
    logic [ADDR_WIDTH-1:0] pop_addr_q;  // pop address latched at return_valid

    // Restored frame state latched from pop_data.
    logic [31:0]          pc_return_q;
    logic [RF_AW-1:0]     tos_base_q;
    logic [RF_AW-1:0]     locals_base_q;

    // One-cycle output pulses.
    logic init_new_frame_q;
    logic return_done_q;
    logic frame_fault_q;

    // --------------------------------------------------------
    // Combinational outputs
    // --------------------------------------------------------
    assign next_locals_base  = new_locals_base_in;
    assign init_new_frame    = init_new_frame_q;
    assign return_done       = return_done_q;
    assign frame_fault       = frame_fault_q;
    assign frame_busy        = (ffsm_q != FS_IDLE);
    assign active_frames_out = depth_q;
    assign pc_return_out     = pc_return_q;
    assign tos_base_out      = tos_base_q;
    assign locals_base_out   = locals_base_q;
    assign head_ptr_out      = (depth_q > 0) ? STACK_BASE_ADDR : '0;
    assign tail_ptr_out      = (depth_q > 0) ?
                               (sp_q - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) : '0;

    // Push address is always sp_q (the current next-free slot).
    assign push_req  = (ffsm_q == FS_PUSHING);
    assign push_addr = sp_q;
    assign push_data = {pc_return_in,
                        tos_base_in,
                        locals_base_in,
                        {(PYCORE_DMEM_DATA_WIDTH - 32 - 2*RF_AW){1'b0}}};

    // Pop address is latched before decrementing sp_q.
    assign pop_req  = (ffsm_q == FS_POPPING);
    assign pop_addr = pop_addr_q;

    // --------------------------------------------------------
    // Sequential logic
    // --------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ffsm_q           <= FS_IDLE;
            depth_q          <= '0;
            sp_q             <= STACK_BASE_ADDR;
            pop_addr_q       <= STACK_BASE_ADDR;
            pc_return_q      <= 32'b0;
            tos_base_q       <= '0;
            locals_base_q    <= '0;
            init_new_frame_q <= 1'b0;
            return_done_q    <= 1'b0;
            frame_fault_q    <= 1'b0;
        end else begin
            // Clear one-cycle pulses by default.
            init_new_frame_q <= 1'b0;
            return_done_q    <= 1'b0;
            frame_fault_q    <= 1'b0;

            unique case (ffsm_q)

                // -------------------------------------------------------
                // FS_IDLE: accept call_valid or return_valid
                // -------------------------------------------------------
                FS_IDLE: begin
                    if (call_valid && return_valid) begin
                        frame_fault_q <= 1'b1;

                    end else if (call_valid) begin
                        if (depth_q >= MAX_CALL_DEPTH) begin
                            frame_fault_q <= 1'b1;
                        end else if ((sp_q + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) >
                                     (STACK_BASE_ADDR +
                                      STACK_SIZE_BYTES[ADDR_WIDTH-1:0])) begin
                            frame_fault_q <= 1'b1;
                        end else begin
                            ffsm_q <= FS_PUSHING;
                        end

                    end else if (return_valid) begin
                        if (depth_q == 0) begin
                            frame_fault_q <= 1'b1;
                        end else begin
                            pop_addr_q <= sp_q - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                            ffsm_q     <= FS_POPPING;
                        end
                    end
                end

                // -------------------------------------------------------
                // FS_PUSHING: wait for core to complete the dmem write
                // -------------------------------------------------------
                FS_PUSHING: begin
                    if (push_ack) begin
                        sp_q             <= sp_q + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        depth_q          <= depth_q + 1'b1;
                        init_new_frame_q <= 1'b1;
                        ffsm_q           <= FS_IDLE;
                    end
                end

                // -------------------------------------------------------
                // FS_POPPING: wait for core to complete the dmem read
                // -------------------------------------------------------
                FS_POPPING: begin
                    if (pop_ack) begin
                        sp_q          <= sp_q - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        depth_q       <= depth_q - 1'b1;
                        pc_return_q   <= pop_data[PC_MSB:PC_LSB];
                        tos_base_q    <= pop_data[TOS_MSB:TOS_LSB];
                        locals_base_q <= pop_data[LOC_MSB:LOC_LSB];
                        return_done_q <= 1'b1;
                        ffsm_q        <= FS_IDLE;
                    end
                end

                default: ffsm_q <= FS_IDLE;
            endcase
        end
    end

endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
