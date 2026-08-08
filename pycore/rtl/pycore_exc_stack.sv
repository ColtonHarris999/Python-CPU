`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// pycore_exc_stack: dmem LIFO of active-exception contexts (§5.5).
//
// Arena: [PYCORE_EXC_STACK_BASE, PYCORE_EXC_STACK_BASE+PYCORE_EXC_STACK_BYTES).
// Each node is 32 bytes:
//   +0  : prev_ptr[31:0] in low word (0 if none)
//   +16 : saved active_exc handle value[127:0]  (tag in bits of a follow-on
//         write is packed as {valid[0], tag[3:0], addr[63:0]} in the
//         companion registers restored by the core — see node layout below)
//
// Node layout used by the core push/pop helpers:
//   slot0 @ node+0  : { 96'b0, prev_ptr[31:0] }
//   slot1 @ node+16 : { active_exc_valid[0], 3'b0, active_exc_tag[3:0],
//                       56'b0, active_exc_addr[63:0] }  — packed for one beat
//
// Push/pop opcode wiring (PUSH_EXC_INFO / POP_EXCEPT) lands in §10 step 5;
// step 4 only needs the arena + reset + register interface.
module pycore_exc_stack #(
    parameter int ADDR_WIDTH = PYCORE_ADDR_WIDTH,
    parameter logic [ADDR_WIDTH-1:0] STACK_BASE_ADDR = PYCORE_EXC_STACK_BASE,
    parameter int STACK_SIZE_BYTES = PYCORE_EXC_STACK_BYTES,
    parameter int NODE_BYTES = PYCORE_EXC_NODE_BYTES,
    parameter int MAX_DEPTH = PYCORE_EXC_STACK_MAX
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    // Combinational status
    output logic [ADDR_WIDTH-1:0] exc_sp_o,
    output logic [ADDR_WIDTH-1:0] exc_head_o,
    output logic                  empty_o,
    output logic                  full_o,
    // Push request: sample prev_ptr / saved active_exc into a new node.
    input  logic                  push_valid_i,
    input  logic [31:0]           push_prev_ptr_i,
    input  logic                  push_exc_valid_i,
    input  logic [3:0]            push_exc_tag_i,
    input  logic [63:0]           push_exc_addr_i,
    output logic                  push_ready_o,
    output logic                  push_fault_o,
    // Pop request: return the head node's saved active_exc and advance.
    input  logic                  pop_valid_i,
    output logic                  pop_ready_o,
    output logic                  pop_fault_o,
    output logic [31:0]           pop_prev_ptr_o,
    output logic                  pop_exc_valid_o,
    output logic [3:0]            pop_exc_tag_o,
    output logic [63:0]           pop_exc_addr_o,
    // dmem master (one outstanding beat)
    output logic                  dmem_req_o,
    output logic                  dmem_we_o,
    output logic [ADDR_WIDTH-1:0] dmem_addr_o,
    output logic [127:0]          dmem_wdata_o,
    input  logic                  dmem_ack_i,
    input  logic [127:0]          dmem_rdata_i
);

    localparam int DEPTH_W = $clog2(MAX_DEPTH + 1);

    localparam logic [1:0] ST_IDLE     = 2'd0;
    localparam logic [1:0] ST_PUSH_S0  = 2'd1;
    localparam logic [1:0] ST_PUSH_S1  = 2'd2;
    localparam logic [1:0] ST_POP_S1   = 2'd3; // pop slot1 first, then slot0 via IDLE helper

    logic [1:0]              state_r;
    logic [DEPTH_W-1:0]      depth_r;
    logic [ADDR_WIDTH-1:0]   sp_r;
    logic [ADDR_WIDTH-1:0]   head_r;
    logic [31:0]             push_prev_r;
    logic                    push_exc_valid_r;
    logic [3:0]              push_exc_tag_r;
    logic [63:0]             push_exc_addr_r;
    logic                    pop_exc_valid_r;
    logic [3:0]              pop_exc_tag_r;
    logic [63:0]             pop_exc_addr_r;
    logic [31:0]             pop_prev_r;
    logic                    push_fault_r;
    logic                    pop_fault_r;
    logic                    push_done_r;
    logic                    pop_done_r;
    logic                    dmem_req_r;
    logic                    dmem_we_r;
    logic [ADDR_WIDTH-1:0]   dmem_addr_r;
    logic [127:0]            dmem_wdata_r;
    logic                    pop_beat0_r; // 0 = reading slot1, 1 = reading slot0

    assign exc_sp_o   = sp_r;
    assign exc_head_o = head_r;
    assign empty_o    = (depth_r == 0);
    assign full_o     = (depth_r >= MAX_DEPTH[DEPTH_W-1:0]);
    assign push_ready_o = push_done_r;
    assign pop_ready_o  = pop_done_r;
    assign push_fault_o = push_fault_r;
    assign pop_fault_o  = pop_fault_r;
    assign pop_prev_ptr_o  = pop_prev_r;
    assign pop_exc_valid_o = pop_exc_valid_r;
    assign pop_exc_tag_o   = pop_exc_tag_r;
    assign pop_exc_addr_o  = pop_exc_addr_r;
    assign dmem_req_o   = dmem_req_r;
    assign dmem_we_o    = dmem_we_r;
    assign dmem_addr_o  = dmem_addr_r;
    assign dmem_wdata_o = dmem_wdata_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r          <= ST_IDLE;
            depth_r          <= '0;
            sp_r             <= STACK_BASE_ADDR;
            head_r           <= '0;
            push_prev_r      <= '0;
            push_exc_valid_r <= 1'b0;
            push_exc_tag_r   <= '0;
            push_exc_addr_r  <= '0;
            pop_exc_valid_r  <= 1'b0;
            pop_exc_tag_r    <= '0;
            pop_exc_addr_r   <= '0;
            pop_prev_r       <= '0;
            push_fault_r     <= 1'b0;
            pop_fault_r      <= 1'b0;
            push_done_r      <= 1'b0;
            pop_done_r       <= 1'b0;
            dmem_req_r       <= 1'b0;
            dmem_we_r        <= 1'b0;
            dmem_addr_r      <= '0;
            dmem_wdata_r     <= '0;
            pop_beat0_r      <= 1'b0;
        end else begin
            push_done_r  <= 1'b0;
            pop_done_r   <= 1'b0;
            push_fault_r <= 1'b0;
            pop_fault_r  <= 1'b0;

            if (dmem_req_r && dmem_ack_i)
                dmem_req_r <= 1'b0;

            unique case (state_r)
                ST_IDLE: begin
                    if (push_valid_i && !pop_valid_i) begin
                        if (full_o ||
                            (sp_r + NODE_BYTES[ADDR_WIDTH-1:0]) >
                            (STACK_BASE_ADDR + STACK_SIZE_BYTES[ADDR_WIDTH-1:0]
                             - 32'd32)) begin
                            // Reserve top 32 B for PYCORE_ITER_EXHAUST_TYPE_ADDR.
                            push_fault_r <= 1'b1;
                            push_done_r  <= 1'b1;
                        end else begin
                            push_prev_r      <= push_prev_ptr_i;
                            push_exc_valid_r <= push_exc_valid_i;
                            push_exc_tag_r   <= push_exc_tag_i;
                            push_exc_addr_r  <= push_exc_addr_i;
                            dmem_addr_r      <= sp_r;
                            dmem_wdata_r     <= {96'b0, push_prev_ptr_i};
                            dmem_we_r        <= 1'b1;
                            dmem_req_r       <= 1'b1;
                            state_r          <= ST_PUSH_S0;
                        end
                    end else if (pop_valid_i && !push_valid_i) begin
                        if (empty_o) begin
                            pop_fault_r <= 1'b1;
                            pop_done_r  <= 1'b1;
                        end else begin
                            dmem_addr_r <= head_r + 16;
                            dmem_we_r   <= 1'b0;
                            dmem_req_r  <= 1'b1;
                            pop_beat0_r <= 1'b0;
                            state_r     <= ST_POP_S1;
                        end
                    end
                end

                ST_PUSH_S0: begin
                    if (!dmem_req_r) begin
                        dmem_addr_r  <= sp_r + 16;
                        dmem_wdata_r <= {push_exc_valid_r, 3'b0,
                                         push_exc_tag_r, 56'b0,
                                         push_exc_addr_r};
                        dmem_we_r    <= 1'b1;
                        dmem_req_r   <= 1'b1;
                        state_r      <= ST_PUSH_S1;
                    end
                end

                ST_PUSH_S1: begin
                    if (!dmem_req_r) begin
                        head_r      <= sp_r;
                        sp_r        <= sp_r + NODE_BYTES[ADDR_WIDTH-1:0];
                        depth_r     <= depth_r + 1'b1;
                        push_done_r <= 1'b1;
                        state_r     <= ST_IDLE;
                    end
                end

                ST_POP_S1: begin
                    if (!dmem_req_r) begin
                        if (!pop_beat0_r) begin
                            pop_exc_valid_r <= dmem_rdata_i[127];
                            pop_exc_tag_r   <= dmem_rdata_i[123:120];
                            pop_exc_addr_r  <= dmem_rdata_i[63:0];
                            dmem_addr_r     <= head_r;
                            dmem_we_r       <= 1'b0;
                            dmem_req_r      <= 1'b1;
                            pop_beat0_r     <= 1'b1;
                        end else begin
                            pop_prev_r  <= dmem_rdata_i[31:0];
                            sp_r        <= head_r;
                            head_r      <= dmem_rdata_i[31:0];
                            depth_r     <= depth_r - 1'b1;
                            pop_done_r  <= 1'b1;
                            state_r     <= ST_IDLE;
                        end
                    end
                end

                default: state_r <= ST_IDLE;
            endcase
        end
    end
endmodule
