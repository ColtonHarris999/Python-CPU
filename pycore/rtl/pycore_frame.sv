`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
module pycore_frame #(
    parameter int MAX_CALL_DEPTH   = 64,
    parameter int FRAME_MAX_SLOTS  = 64,
    parameter int RF_DEPTH         = 96,
    parameter int RF_BASE          = 32,
    parameter int ADDR_WIDTH       = PYCORE_ADDR_WIDTH,
    parameter logic [ADDR_WIDTH-1:0] STACK_BASE_ADDR  = 32'h0001_0000,
    parameter int STACK_SIZE_BYTES = 32'h0001_0000,
    parameter int FRAME_NODE_BYTES = 32'd256,
    parameter logic [ADDR_WIDTH-1:0] SPILL_BASE_ADDR  = 32'h0002_0000,
    parameter int SPILL_SIZE_BYTES  = 32'h0008_0000,
    parameter int SPILL_SLOT_BYTES  = 16
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         call_valid,
    input  logic                         return_valid,
    input  logic [31:0]                  pc_return_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  tos_base_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  locals_base_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_in,
    input  logic [$clog2(FRAME_MAX_SLOTS+1)-1:0] frame_slots_in,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] return_value_in,
    output logic [31:0]                  pc_return_out,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  next_locals_base,
    output logic                         init_new_frame,
    output logic [PYCORE_ENTRY_WIDTH-1:0] return_value_out,
    output logic [ADDR_WIDTH-1:0]        head_ptr_out,
    output logic [ADDR_WIDTH-1:0]        tail_ptr_out,
    output logic [ADDR_WIDTH-1:0]        alloc_ptr_out,
    output logic [$clog2(MAX_CALL_DEPTH+1)-1:0] active_frames_out,
    output logic [$clog2(RF_DEPTH-RF_BASE+1)-1:0] resident_regs_out,
    output logic                         frame_fault
);

    localparam int DEPTH_W     = $clog2(MAX_CALL_DEPTH + 1);
    localparam int FRAME_IDX_W = (MAX_CALL_DEPTH > 1) ? $clog2(MAX_CALL_DEPTH) : 1;
    localparam int SLOT_W      = (FRAME_MAX_SLOTS > 1) ? $clog2(FRAME_MAX_SLOTS) : 1;
    localparam int SLOT_CNT_W  = $clog2(FRAME_MAX_SLOTS + 1);
    localparam int RF_AW       = $clog2(RF_DEPTH);
    localparam int REG_CAP     = RF_DEPTH - RF_BASE;
    localparam int REG_CAP_W   = $clog2(REG_CAP + 1);
    localparam int QIDX_W      = (REG_CAP > 1) ? $clog2(REG_CAP) : 1;
    localparam int SPILL_SLOTS = SPILL_SIZE_BYTES / SPILL_SLOT_BYTES;
    localparam int SPILL_W     = (SPILL_SLOTS > 1) ? $clog2(SPILL_SLOTS) : 1;
    localparam int SPILL_CNT_W = $clog2(SPILL_SLOTS + 1);

    logic [31:0] frame_pc [0:MAX_CALL_DEPTH-1];
    logic [RF_AW-1:0] frame_tos [0:MAX_CALL_DEPTH-1];
    logic [RF_AW-1:0] frame_locals [0:MAX_CALL_DEPTH-1];
    logic [ADDR_WIDTH-1:0] frame_node_addr [0:MAX_CALL_DEPTH-1];
    logic [ADDR_WIDTH-1:0] frame_prev_ptr [0:MAX_CALL_DEPTH-1];
    logic [ADDR_WIDTH-1:0] frame_next_ptr [0:MAX_CALL_DEPTH-1];
    logic [SLOT_CNT_W-1:0] frame_slot_count [0:MAX_CALL_DEPTH-1];
    logic [SLOT_CNT_W-1:0] frame_resident_count [0:MAX_CALL_DEPTH-1];
    logic [SLOT_CNT_W-1:0] frame_spill_count [0:MAX_CALL_DEPTH-1];
    logic frame_active [0:MAX_CALL_DEPTH-1];

    logic slot_resident [0:MAX_CALL_DEPTH-1][0:FRAME_MAX_SLOTS-1];
    logic [RF_AW-1:0] slot_reg_idx [0:MAX_CALL_DEPTH-1][0:FRAME_MAX_SLOTS-1];
    logic [ADDR_WIDTH-1:0] slot_map_addr [0:MAX_CALL_DEPTH-1][0:FRAME_MAX_SLOTS-1];

    logic [FRAME_IDX_W-1:0] resident_frame_q [0:REG_CAP-1];
    logic [SLOT_W-1:0] resident_slot_q [0:REG_CAP-1];
    logic [RF_AW-1:0] resident_reg_q [0:REG_CAP-1];
    logic [QIDX_W-1:0] resident_head_q;
    logic [REG_CAP_W-1:0] resident_count_q;

    logic reg_in_use [0:RF_DEPTH-1];
    logic spill_slot_used [0:SPILL_SLOTS-1];
    logic [SPILL_W-1:0] next_spill_slot_q;
    logic [SPILL_CNT_W-1:0] spill_used_count_q;
    logic [RF_AW-1:0] next_reg_q;
    logic [ADDR_WIDTH-1:0] next_node_addr_q;
    logic [DEPTH_W-1:0] sp;
    logic frame_fault_q;
    logic init_new_frame_q;

    function automatic logic [RF_AW-1:0] wrap_reg(input logic [RF_AW-1:0] reg_idx);
        begin
            if (reg_idx == RF_DEPTH-1) begin
                wrap_reg = RF_BASE[RF_AW-1:0];
            end else begin
                wrap_reg = reg_idx + 1'b1;
            end
        end
    endfunction

    assign pc_return_out = (sp > 0) ? frame_pc[sp-1] : 32'b0;
    assign tos_base_out = (sp > 0) ? frame_tos[sp-1] : '0;
    assign locals_base_out = (sp > 0) ? frame_locals[sp-1] : '0;
    assign next_locals_base = new_locals_base_in;
    assign init_new_frame = init_new_frame_q;
    assign return_value_out = return_value_in;
    assign head_ptr_out = (sp > 0) ? frame_node_addr[0] : '0;
    assign tail_ptr_out = (sp > 0) ? frame_node_addr[sp-1] : '0;
    assign alloc_ptr_out = (resident_count_q > 0) ? frame_node_addr[resident_frame_q[resident_head_q]] : '0;
    assign active_frames_out = sp;
    assign resident_regs_out = resident_count_q;
    assign frame_fault = frame_fault_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int i;
            int j;

            sp = '0;
            frame_fault_q = 1'b0;
            init_new_frame_q = 1'b0;
            resident_head_q = '0;
            resident_count_q = '0;
            next_reg_q = RF_BASE[RF_AW-1:0];
            next_node_addr_q = STACK_BASE_ADDR;
            next_spill_slot_q = '0;
            spill_used_count_q = '0;

            for (i = 0; i < MAX_CALL_DEPTH; i++) begin
                frame_pc[i] = 32'b0;
                frame_tos[i] = '0;
                frame_locals[i] = '0;
                frame_node_addr[i] = '0;
                frame_prev_ptr[i] = '0;
                frame_next_ptr[i] = '0;
                frame_slot_count[i] = '0;
                frame_resident_count[i] = '0;
                frame_spill_count[i] = '0;
                frame_active[i] = 1'b0;
                for (j = 0; j < FRAME_MAX_SLOTS; j++) begin
                    slot_resident[i][j] = 1'b0;
                    slot_reg_idx[i][j] = RF_BASE[RF_AW-1:0];
                    slot_map_addr[i][j] = '0;
                end
            end

            for (i = 0; i < REG_CAP; i++) begin
                resident_frame_q[i] = '0;
                resident_slot_q[i] = '0;
                resident_reg_q[i] = RF_BASE[RF_AW-1:0];
            end

            for (i = 0; i < RF_DEPTH; i++) begin
                reg_in_use[i] = 1'b0;
            end

            for (i = 0; i < SPILL_SLOTS; i++) begin
                spill_slot_used[i] = 1'b0;
            end
        end else begin
            int frame_idx;
            int slot_idx;
            int q_idx;
            int scan_idx;
            int spill_slot_idx;
            int available_regs;
            int spill_needed;
            int spill_free;
            int old_frame_idx;
            int old_slot_idx;
            int old_reg_idx;
            int tail_idx;
            int scan_reg_idx;
            int alloc_reg_idx;
            bit found_free_reg;
            bit alloc_fault;

            frame_fault_q = 1'b0;
            init_new_frame_q = 1'b0;

            if (call_valid && return_valid) begin
                frame_fault_q = 1'b1;
            end else if (call_valid) begin
                if (REG_CAP <= 0 || SPILL_SLOTS <= 0) begin
                    frame_fault_q = 1'b1;
                end else if (sp >= MAX_CALL_DEPTH) begin
                    frame_fault_q = 1'b1;
                end else if (frame_slots_in > FRAME_MAX_SLOTS) begin
                    frame_fault_q = 1'b1;
                end else if ((next_node_addr_q + FRAME_NODE_BYTES) > (STACK_BASE_ADDR + STACK_SIZE_BYTES)) begin
                    frame_fault_q = 1'b1;
                end else begin
                    available_regs = REG_CAP - resident_count_q;
                    spill_needed = (frame_slots_in > available_regs) ? (frame_slots_in - available_regs) : 0;
                    spill_free = SPILL_SLOTS - spill_used_count_q;

                    if (spill_needed > spill_free) begin
                        frame_fault_q = 1'b1;
                    end else begin
                        frame_idx = sp;
                        frame_pc[frame_idx] = pc_return_in;
                        frame_tos[frame_idx] = tos_base_in;
                        frame_locals[frame_idx] = locals_base_in;
                        frame_node_addr[frame_idx] = next_node_addr_q;
                        frame_prev_ptr[frame_idx] = (frame_idx > 0) ? frame_node_addr[frame_idx-1] : '0;
                        frame_next_ptr[frame_idx] = '0;
                        frame_slot_count[frame_idx] = frame_slots_in;
                        frame_resident_count[frame_idx] = '0;
                        frame_spill_count[frame_idx] = '0;
                        frame_active[frame_idx] = 1'b1;

                        if (frame_idx > 0) begin
                            frame_next_ptr[frame_idx-1] = next_node_addr_q;
                        end

                        next_node_addr_q = next_node_addr_q + FRAME_NODE_BYTES;
                        alloc_fault = 1'b0;

                        for (slot_idx = 0; slot_idx < FRAME_MAX_SLOTS; slot_idx++) begin
                            slot_resident[frame_idx][slot_idx] = 1'b0;
                            slot_reg_idx[frame_idx][slot_idx] = RF_BASE[RF_AW-1:0];
                            slot_map_addr[frame_idx][slot_idx] = '0;
                        end

                        for (slot_idx = 0; slot_idx < frame_slots_in; slot_idx++) begin
                            if (resident_count_q >= REG_CAP) begin
                                q_idx = resident_head_q;
                                old_frame_idx = resident_frame_q[q_idx];
                                old_slot_idx = resident_slot_q[q_idx];
                                old_reg_idx = resident_reg_q[q_idx];

                                spill_slot_idx = -1;
                                for (scan_idx = 0; scan_idx < SPILL_SLOTS; scan_idx++) begin
                                    q_idx = next_spill_slot_q + scan_idx;
                                    if (q_idx >= SPILL_SLOTS) begin
                                        q_idx = q_idx - SPILL_SLOTS;
                                    end
                                    if (!spill_slot_used[q_idx] && spill_slot_idx < 0) begin
                                        spill_slot_idx = q_idx;
                                    end
                                end

                                if (spill_slot_idx < 0) begin
                                    alloc_fault = 1'b1;
                                end else begin
                                    spill_slot_used[spill_slot_idx] = 1'b1;
                                    spill_used_count_q = spill_used_count_q + 1'b1;
                                    next_spill_slot_q = (spill_slot_idx == SPILL_SLOTS-1) ? '0 :
                                                        spill_slot_idx + 1'b1;
                                    slot_map_addr[old_frame_idx][old_slot_idx] =
                                        SPILL_BASE_ADDR + (spill_slot_idx * SPILL_SLOT_BYTES);
                                    slot_resident[old_frame_idx][old_slot_idx] = 1'b0;
                                    reg_in_use[old_reg_idx] = 1'b0;
                                    if (frame_resident_count[old_frame_idx] > 0) begin
                                        frame_resident_count[old_frame_idx] =
                                            frame_resident_count[old_frame_idx] - 1'b1;
                                    end
                                    frame_spill_count[old_frame_idx] =
                                        frame_spill_count[old_frame_idx] + 1'b1;
                                    resident_head_q = (resident_head_q == REG_CAP-1) ? '0 :
                                                      resident_head_q + 1'b1;
                                    resident_count_q = resident_count_q - 1'b1;
                                end
                            end

                            found_free_reg = 1'b0;
                            alloc_reg_idx = RF_BASE;
                            for (scan_idx = 0; scan_idx < REG_CAP; scan_idx++) begin
                                scan_reg_idx = next_reg_q + scan_idx;
                                if (scan_reg_idx > RF_DEPTH-1) begin
                                    scan_reg_idx = scan_reg_idx - REG_CAP;
                                end
                                if (!reg_in_use[scan_reg_idx] && !found_free_reg) begin
                                    alloc_reg_idx = scan_reg_idx;
                                    found_free_reg = 1'b1;
                                end
                            end

                            if (!found_free_reg) begin
                                alloc_fault = 1'b1;
                            end else begin
                                reg_in_use[alloc_reg_idx] = 1'b1;
                                slot_resident[frame_idx][slot_idx] = 1'b1;
                                slot_reg_idx[frame_idx][slot_idx] = alloc_reg_idx[RF_AW-1:0];
                                slot_map_addr[frame_idx][slot_idx] = '0;
                                frame_resident_count[frame_idx] =
                                    frame_resident_count[frame_idx] + 1'b1;
                                next_reg_q = wrap_reg(alloc_reg_idx[RF_AW-1:0]);

                                tail_idx = resident_head_q + resident_count_q;
                                if (tail_idx >= REG_CAP) begin
                                    tail_idx = tail_idx - REG_CAP;
                                end
                                resident_frame_q[tail_idx] = frame_idx[FRAME_IDX_W-1:0];
                                resident_slot_q[tail_idx] = slot_idx[SLOT_W-1:0];
                                resident_reg_q[tail_idx] = alloc_reg_idx[RF_AW-1:0];
                                resident_count_q = resident_count_q + 1'b1;
                            end
                        end

                        if (alloc_fault) begin
                            frame_fault_q = 1'b1;
                        end else begin
                            sp = sp + 1'b1;
                            init_new_frame_q = 1'b1;
                        end
                    end
                end
            end else if (return_valid) begin
                if (sp > 0) begin
                    frame_idx = sp - 1'b1;

                    // Pop this frame's resident slots from queue tail and release regs.
                    while (resident_count_q > 0) begin
                        tail_idx = resident_head_q + resident_count_q - 1;
                        if (tail_idx >= REG_CAP) begin
                            tail_idx = tail_idx - REG_CAP;
                        end
                        if (resident_frame_q[tail_idx] == frame_idx[FRAME_IDX_W-1:0]) begin
                            reg_in_use[resident_reg_q[tail_idx]] = 1'b0;
                            resident_count_q = resident_count_q - 1'b1;
                        end else begin
                            break;
                        end
                    end

                    // Free any spill storage owned by the frame.
                    for (slot_idx = 0; slot_idx < frame_slot_count[frame_idx]; slot_idx++) begin
                        if (slot_map_addr[frame_idx][slot_idx] != 0) begin
                            spill_slot_idx = (slot_map_addr[frame_idx][slot_idx] - SPILL_BASE_ADDR) /
                                             SPILL_SLOT_BYTES;
                            if ((spill_slot_idx >= 0) && (spill_slot_idx < SPILL_SLOTS) &&
                                spill_slot_used[spill_slot_idx]) begin
                                spill_slot_used[spill_slot_idx] = 1'b0;
                                if (spill_used_count_q > 0) begin
                                    spill_used_count_q = spill_used_count_q - 1'b1;
                                end
                            end
                        end
                    end

                    frame_pc[frame_idx] = 32'b0;
                    frame_tos[frame_idx] = '0;
                    frame_locals[frame_idx] = '0;
                    frame_node_addr[frame_idx] = '0;
                    frame_prev_ptr[frame_idx] = '0;
                    frame_next_ptr[frame_idx] = '0;
                    frame_slot_count[frame_idx] = '0;
                    frame_resident_count[frame_idx] = '0;
                    frame_spill_count[frame_idx] = '0;
                    frame_active[frame_idx] = 1'b0;
                    for (slot_idx = 0; slot_idx < FRAME_MAX_SLOTS; slot_idx++) begin
                        slot_resident[frame_idx][slot_idx] = 1'b0;
                        slot_reg_idx[frame_idx][slot_idx] = RF_BASE[RF_AW-1:0];
                        slot_map_addr[frame_idx][slot_idx] = '0;
                    end

                    if (frame_idx > 0) begin
                        frame_next_ptr[frame_idx-1] = '0;
                    end

                    sp = sp - 1'b1;
                    if (next_node_addr_q >= (STACK_BASE_ADDR + FRAME_NODE_BYTES)) begin
                        next_node_addr_q = next_node_addr_q - FRAME_NODE_BYTES;
                    end
                    if (resident_count_q == 0) begin
                        resident_head_q = '0;
                    end
                end else begin
                    frame_fault_q = 1'b1;
                end
            end
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
