`include "pycore_defs.svh"

module pycore_trap (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        type_trap,
    input  logic        stack_fault,
    input  logic        div_zero,
    input  logic        fpu_exception,
    input  logic        illegal_opcode,
    input  logic [31:0] fault_pc,
    input  logic [66:0] fault_rs1,
    input  logic [66:0] fault_rs2,
    output logic        trap_out,
    output logic [3:0]  trap_code,
    output logic [31:0] trap_pc,
    output logic [66:0] trap_rs1,
    output logic [66:0] trap_rs2,
    output logic        freeze_pipeline
);

    logic next_trap;
    logic [3:0] next_code;

    always_comb begin
        next_trap = type_trap || stack_fault || div_zero || fpu_exception || illegal_opcode;
        if (type_trap) begin
            next_code = PY_TRAP_TYPE;
        end else if (stack_fault) begin
            next_code = PY_TRAP_STACK;
        end else if (div_zero) begin
            next_code = PY_TRAP_DIV_ZERO;
        end else if (fpu_exception) begin
            next_code = PY_TRAP_FPU_EXCEPTION;
        end else if (illegal_opcode) begin
            next_code = PY_TRAP_ILLEGAL_OPCODE;
        end else begin
            next_code = PY_TRAP_NONE;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trap_out <= 1'b0;
            trap_code <= PY_TRAP_NONE;
            trap_pc <= 32'b0;
            trap_rs1 <= 67'b0;
            trap_rs2 <= 67'b0;
        end else if (!trap_out && next_trap) begin
            trap_out <= 1'b1;
            trap_code <= next_code;
            trap_pc <= fault_pc;
            trap_rs1 <= fault_rs1;
            trap_rs2 <= fault_rs2;
        end
    end

    assign freeze_pipeline = trap_out || next_trap;

endmodule
