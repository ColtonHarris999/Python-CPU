import pycore_types_pkg::*;

module pycore_trap (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear_trap,
    input  logic [31:0] trap_pc_in,
    input  logic [65:0] trap_tos_in,
    input  logic        stage_type_trap,
    input  logic        stage_stack_fault,
    input  logic        stage_div_zero,
    input  logic        stage_illegal_opcode,
    input  logic        stage_frame_fault,
    output logic        trap_out,
    output logic [3:0]  trap_code,
    output logic [31:0] trap_pc,
    output logic [63:0] trap_tos_val,
    output logic [1:0]  trap_tos_tag
);
    logic        trap_any;
    logic [3:0]  trap_code_next;

    always_comb begin
        trap_any = stage_type_trap || stage_stack_fault || stage_div_zero || stage_illegal_opcode || stage_frame_fault;
        trap_code_next = TRAP_NONE;

        if (stage_type_trap) begin
            trap_code_next = TRAP_TYPE;
        end else if (stage_stack_fault) begin
            trap_code_next = TRAP_STACK;
        end else if (stage_div_zero) begin
            trap_code_next = TRAP_DIV_ZERO;
        end else if (stage_illegal_opcode) begin
            trap_code_next = TRAP_ILLEGAL;
        end else if (stage_frame_fault) begin
            trap_code_next = TRAP_FRAME;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trap_out <= 1'b0;
            trap_code <= TRAP_NONE;
            trap_pc <= 32'd0;
            trap_tos_val <= 64'd0;
            trap_tos_tag <= TAG_UNINIT;
        end else if (clear_trap) begin
            trap_out <= 1'b0;
            trap_code <= TRAP_NONE;
            trap_pc <= 32'd0;
            trap_tos_val <= 64'd0;
            trap_tos_tag <= TAG_UNINIT;
        end else if (!trap_out && trap_any) begin
            trap_out <= 1'b1;
            trap_code <= trap_code_next;
            trap_pc <= trap_pc_in;
            trap_tos_val <= trap_tos_in[63:0];
            trap_tos_tag <= trap_tos_in[65:64];
        end
    end
endmodule
