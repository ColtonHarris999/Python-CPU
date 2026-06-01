module pycore_frame #(
    parameter int MAX_CALL_DEPTH = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        call_en,
    input  logic        return_en,
    input  logic [31:0] call_target,
    input  logic [31:0] return_pc_in,
    input  logic [6:0]  tos_ptr_in,
    input  logic [6:0]  locals_base_in,
    output logic [31:0] pc_out,
    output logic [6:0]  tos_ptr_out,
    output logic [6:0]  locals_base_out,
    output logic        frame_fault
);
    localparam int DEPTH_W = (MAX_CALL_DEPTH > 1) ? $clog2(MAX_CALL_DEPTH + 1) : 1;

    logic [31:0] ret_pc_mem      [0:MAX_CALL_DEPTH-1];
    logic [6:0]  ret_tos_mem     [0:MAX_CALL_DEPTH-1];
    logic [6:0]  ret_locals_mem  [0:MAX_CALL_DEPTH-1];
    logic [DEPTH_W-1:0] sp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp <= '0;
            pc_out <= 32'd0;
            tos_ptr_out <= 7'd0;
            locals_base_out <= 7'd0;
            frame_fault <= 1'b0;
        end else begin
            frame_fault <= 1'b0;
            pc_out <= 32'd0;
            tos_ptr_out <= tos_ptr_in;
            locals_base_out <= locals_base_in;

            if (call_en) begin
                if (sp < MAX_CALL_DEPTH) begin
                    ret_pc_mem[sp] <= return_pc_in;
                    ret_tos_mem[sp] <= tos_ptr_in;
                    ret_locals_mem[sp] <= locals_base_in;
                    sp <= sp + 1'b1;
                    pc_out <= call_target;
                    locals_base_out <= 7'd0;
                end else begin
                    frame_fault <= 1'b1;
                end
            end else if (return_en) begin
                if (sp > 0) begin
                    sp <= sp - 1'b1;
                    pc_out <= ret_pc_mem[sp-1];
                    tos_ptr_out <= ret_tos_mem[sp-1];
                    locals_base_out <= ret_locals_mem[sp-1];
                end else begin
                    frame_fault <= 1'b1;
                end
            end
        end
    end
endmodule
