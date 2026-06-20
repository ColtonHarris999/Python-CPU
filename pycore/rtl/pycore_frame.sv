`include "pycore_defs.svh"

module pycore_frame #(
    parameter int MAX_CALL_DEPTH = 16,
    parameter int RF_DEPTH = 96
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         call_valid,
    input  logic                         return_valid,
    input  logic [31:0]                  pc_return_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  tos_base_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  locals_base_in,
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_in,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] return_value_in,
    output logic [31:0]                  pc_return_out,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_out,
    output logic [$clog2(RF_DEPTH)-1:0]  next_locals_base,
    output logic                         init_new_frame,
    output logic [PYCORE_ENTRY_WIDTH-1:0] return_value_out,
    output logic                         frame_fault
);

    localparam int DEPTH_W = $clog2(MAX_CALL_DEPTH + 1);

    logic [31:0] pc_stack [0:MAX_CALL_DEPTH-1];
    logic [$clog2(RF_DEPTH)-1:0] tos_stack [0:MAX_CALL_DEPTH-1];
    logic [$clog2(RF_DEPTH)-1:0] locals_stack [0:MAX_CALL_DEPTH-1];
    logic [DEPTH_W-1:0] sp;
    logic frame_fault_q;

    assign pc_return_out = (sp > 0) ? pc_stack[sp-1] : 32'b0;
    assign tos_base_out = (sp > 0) ? tos_stack[sp-1] : '0;
    assign locals_base_out = (sp > 0) ? locals_stack[sp-1] : '0;
    assign next_locals_base = new_locals_base_in;
    assign init_new_frame = call_valid && !frame_fault_q;
    assign return_value_out = return_value_in;
    assign frame_fault = frame_fault_q ||
                         (call_valid && sp == MAX_CALL_DEPTH[DEPTH_W-1:0]) ||
                         (return_valid && sp == '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp <= '0;
            frame_fault_q <= 1'b0;
        end else begin
            frame_fault_q <= 1'b0;
            if (call_valid && return_valid) begin
                frame_fault_q <= 1'b1;
            end else if (call_valid) begin
                if (sp < MAX_CALL_DEPTH[DEPTH_W-1:0]) begin
                    pc_stack[sp] <= pc_return_in;
                    tos_stack[sp] <= tos_base_in;
                    locals_stack[sp] <= locals_base_in;
                    sp <= sp + 1'b1;
                end else begin
                    frame_fault_q <= 1'b1;
                end
            end else if (return_valid) begin
                if (sp > 0) begin
                    sp <= sp - 1'b1;
                end else begin
                    frame_fault_q <= 1'b1;
                end
            end
        end
    end

endmodule
