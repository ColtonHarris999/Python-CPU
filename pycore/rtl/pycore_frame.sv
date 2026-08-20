`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// pycore_frame: call-frame manager for the PyCore CPU.
//
// Frame descriptor — two 128-bit dmem slots (32 bytes/frame):
//
//   Slot 0 (push first / pop second):
//     bits [127:96]  pc_return[31:0]
//     bits [95:95-RF_AW+1]  tos_base[RF_AW-1:0]
//     bits […:…]     locals_base[RF_AW-1:0]
//     remaining      zero
//
//   Slot 1 (push second / pop first):
//     bits [31:0]    caller cur_code_r (code-object byte address)
//     bit  [32]      ret_discard_push_self for the frame being entered
//     bits [96:33]   saved_instance_addr (64 bits) for that frame
//     bits [127:97]  caller globals_base_r[30:0] (Plan 1 P4)
//                    dmem is 128 KB, so bit 31 of the address is always 0
//                    and 31 bits are enough without growing the descriptor.
//
// On return the core re-reads the caller's co_consts / co_names from the
// restored code object (2 field reads). Slot1's ret-mode / saved-instance
// describe what S_RETURN should do for the function that just returned
// (e.g. TYPE.__init__ discards NONE and pushes the instance).
//
// The stack grows upward from STACK_BASE_ADDR; sp_r always points to the
// NEXT free byte. Depth is bounded by MAX_CALL_DEPTH.
//
// FSM:
//   FS_IDLE     – accept call_valid_i or return_valid_i
//   FS_PUSHING  – two-beat dmem write (slot0 then slot1); init_new_frame_o
//                 on the second push_ack_i
//   FS_POPPING  – two-beat dmem read (slot1 then slot0); return_done_o on
//                 the second pop_ack_i
//
// FRAME_ENTRY_BYTES = 32 (two 16-byte dmem words). The 8 KB frame region
// still holds 256 frames.
module pycore_frame #(
    parameter int MAX_CALL_DEPTH   = 128,
    parameter int RF_DEPTH         = 256,
    parameter int RF_BASE          = 32,
    parameter int ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter logic [ADDR_WIDTH-1:0] STACK_BASE_ADDR  = 32'h0001_0000,
    parameter int STACK_SIZE_BYTES = 32'h0001_0000,
    // Two 128-bit slots per frame.
    parameter int FRAME_ENTRY_BYTES = 32,
    parameter int FRAME_SLOT_BYTES  = 16
) (
    input  logic                         clk_i,
    input  logic                         rst_n_i,
    input  logic                         call_valid_i,
    input  logic                         return_valid_i,
    input  logic [31:0]                  pc_return_in_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  tos_base_in_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  locals_base_in_i,
    input  logic [31:0]                  cur_code_in_i,
    input  logic                         ret_mode_in_i,
    input  logic [63:0]                  saved_inst_in_i,
    input  logic [31:0]                  globals_base_in_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_in_i,
    output logic [31:0]                  pc_return_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_base_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_out_o,
    output logic [31:0]                  cur_code_out_o,
    output logic                         ret_mode_out_o,
    output logic [63:0]                  saved_inst_out_o,
    output logic [31:0]                  globals_base_out_o,
    output logic [$clog2(RF_DEPTH)-1:0]  next_locals_base_o,
    output logic                         init_new_frame_o,
    output logic                         return_done_o,
    output logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out_o,
    output logic [ADDR_WIDTH-1:0]        head_ptr_out_o,
    output logic [ADDR_WIDTH-1:0]        tail_ptr_out_o,
    output logic                         frame_fault_o,
    output logic                         frame_busy_o,
    output logic                         push_req_o,
    output logic [ADDR_WIDTH-1:0]        push_addr_o,
    output logic [PYCORE_DMEM_DATA_WIDTH-1:0] push_data_o,
    input  logic                         push_ack_i,
    output logic                         pop_req_o,
    output logic [ADDR_WIDTH-1:0]        pop_addr_o,
    input  logic [PYCORE_DMEM_DATA_WIDTH-1:0] pop_data_i,
    input  logic                         pop_ack_i
);

    localparam int DEPTH_W = $clog2(MAX_CALL_DEPTH + 1);
    localparam int RF_AW   = $clog2(RF_DEPTH);

    localparam int PC_MSB  = PYCORE_DMEM_DATA_WIDTH - 1;              // 127
    localparam int PC_LSB  = PYCORE_DMEM_DATA_WIDTH - 32;             // 96
    localparam int TOS_MSB = PYCORE_DMEM_DATA_WIDTH - 32 - 1;         // 95
    localparam int TOS_LSB = PYCORE_DMEM_DATA_WIDTH - 32 - RF_AW;     // 89
    localparam int LOC_MSB = PYCORE_DMEM_DATA_WIDTH - 32 - RF_AW - 1; // 88
    localparam int LOC_LSB = PYCORE_DMEM_DATA_WIDTH - 32 - 2*RF_AW;   // 82

    localparam logic [1:0] FS_IDLE    = 2'd0;
    localparam logic [1:0] FS_PUSHING = 2'd1;
    localparam logic [1:0] FS_POPPING = 2'd2;

    logic [1:0]            state_r;
    logic [1:0]            state_next;
    logic                  beat_r;      // 0 = first slot, 1 = second slot

    logic [DEPTH_W-1:0]   depth_r;
    logic [ADDR_WIDTH-1:0] sp_r;
    logic [ADDR_WIDTH-1:0] pop_addr_r;

    logic [31:0]          pc_return_r;
    logic [RF_AW-1:0]     tos_base_r;
    logic [RF_AW-1:0]     locals_base_r;
    logic [31:0]          cur_code_r;
    logic                 ret_mode_r;
    logic [63:0]          saved_inst_r;
    logic [30:0]          globals_base_r;

    logic init_new_frame_r;
    logic return_done_r;
    logic frame_fault_r;

    assign next_locals_base_o  = new_locals_base_in_i;
    assign init_new_frame_o    = init_new_frame_r;
    assign return_done_o       = return_done_r;
    assign frame_fault_o       = frame_fault_r;
    assign frame_busy_o        = (state_r != FS_IDLE);
    assign active_frames_out_o = depth_r;
    assign pc_return_out_o     = pc_return_r;
    assign tos_base_out_o      = tos_base_r;
    assign locals_base_out_o   = locals_base_r;
    assign cur_code_out_o      = cur_code_r;
    assign ret_mode_out_o      = ret_mode_r;
    assign saved_inst_out_o    = saved_inst_r;
    assign globals_base_out_o  = {1'b0, globals_base_r};
    assign head_ptr_out_o      = (depth_r > 0) ? STACK_BASE_ADDR : '0;
    assign tail_ptr_out_o      = (depth_r > 0) ?
                               (sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0]) : '0;

    // Push: beat0 writes slot0 at sp_r; beat1 writes slot1 at sp_r+16.
    // Slot1: [31:0]=cur_code, [32]=ret_mode, [96:33]=saved_inst,
    //        [127:97]=globals_base[30:0].
    assign push_req_o  = (state_r == FS_PUSHING);
    assign push_addr_o = beat_r ? (sp_r + FRAME_SLOT_BYTES[ADDR_WIDTH-1:0]) : sp_r;
    assign push_data_o = beat_r ?
        {globals_base_in_i[30:0],
         saved_inst_in_i,
         ret_mode_in_i,
         cur_code_in_i} :
        {pc_return_in_i,
         tos_base_in_i,
         locals_base_in_i,
         {(PYCORE_DMEM_DATA_WIDTH - 32 - 2*RF_AW){1'b0}}};

    assign pop_req_o  = (state_r == FS_POPPING);
    assign pop_addr_o = pop_addr_r;

    always_comb begin
        state_next = state_r;
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
            end
            FS_PUSHING: begin
                if (push_ack_i && beat_r) state_next = FS_IDLE;
            end
            FS_POPPING: begin
                if (pop_ack_i && beat_r) state_next = FS_IDLE;
            end
            default: state_next = FS_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r          <= FS_IDLE;
            beat_r           <= 1'b0;
            depth_r          <= '0;
            sp_r             <= STACK_BASE_ADDR;
            pop_addr_r       <= STACK_BASE_ADDR;
            pc_return_r      <= 32'b0;
            tos_base_r       <= '0;
            locals_base_r    <= '0;
            cur_code_r       <= 32'b0;
            ret_mode_r       <= 1'b0;
            saved_inst_r     <= 64'b0;
            globals_base_r   <= 31'b0;
            init_new_frame_r <= 1'b0;
            return_done_r    <= 1'b0;
            frame_fault_r    <= 1'b0;
        end else begin
            state_r <= state_next;

            init_new_frame_r <= 1'b0;
            return_done_r    <= 1'b0;
            frame_fault_r    <= 1'b0;

            unique case (state_r)

                FS_IDLE: begin
                    beat_r <= 1'b0;
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
                    end else if (return_valid_i) begin
                        if (depth_r == 0) begin
                            frame_fault_r <= 1'b1;
                        end else begin
                            // Pop slot1 first (at sp-16), then slot0 (at sp-32).
                            pop_addr_r <= sp_r - FRAME_SLOT_BYTES[ADDR_WIDTH-1:0];
                        end
                    end
                end

                FS_PUSHING: begin
                    if (push_ack_i) begin
                        if (!beat_r) begin
                            beat_r <= 1'b1;
                        end else begin
                            sp_r             <= sp_r + FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                            depth_r          <= depth_r + 1'b1;
                            beat_r           <= 1'b0;
                            init_new_frame_r <= 1'b1;
                        end
                    end
                end

                FS_POPPING: begin
                    if (pop_ack_i) begin
                        if (!beat_r) begin
                            // First beat: slot1 → cur_code / ret_mode /
                            // saved_inst / globals_base
                            cur_code_r     <= pop_data_i[31:0];
                            ret_mode_r     <= pop_data_i[32];
                            saved_inst_r   <= pop_data_i[96:33];
                            globals_base_r <= pop_data_i[127:97];
                            beat_r       <= 1'b1;
                            pop_addr_r   <= sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                        end else begin
                            // Second beat: slot0 → pc/tos/locals
                            sp_r          <= sp_r - FRAME_ENTRY_BYTES[ADDR_WIDTH-1:0];
                            depth_r       <= depth_r - 1'b1;
                            pc_return_r   <= pop_data_i[PC_MSB:PC_LSB];
                            tos_base_r    <= pop_data_i[TOS_MSB:TOS_LSB];
                            locals_base_r <= pop_data_i[LOC_MSB:LOC_LSB];
                            beat_r        <= 1'b0;
                            return_done_r <= 1'b1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
