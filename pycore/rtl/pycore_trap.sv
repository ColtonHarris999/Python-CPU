`include "pycore_defs.svh"

module pycore_trap (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        type_trap_i,
    input  logic        stack_fault_i,
    input  logic        div_zero_i,
    input  logic        fpu_exception_i,
    input  logic        illegal_opcode_i,
    input  logic        call_filter_i,
    input  logic        mem_fault_i,
    input  logic        addr_align_i,
    // PY_TRAP_LIST_GROW: full-list LIST_APPEND (Phase A: fatal; Phase C:
    // routed to the excore before reaching this module when EXCORE_EN and
    // pycore_trap_recoverable(code) both hold).
    input  logic        list_grow_i,
    // PY_TRAP_LIST_EXTEND: LIST_EXTEND that needs a grow (same routing).
    input  logic        list_extend_i,
    // Phase C: the excore reported RES_FATAL for a recoverable trap it was
    // handed (S_TRAP_WAIT). excore_fatal_code_i is forwarded verbatim as
    // trap_code_o rather than mapped through a fixed one-hot condition,
    // since it can be any PY_TRAP_* code the firmware chooses to report.
    input  logic        excore_fatal_i,
    input  logic [3:0]  excore_fatal_code_i,
    input  logic [31:0] fault_pc_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs1_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] fault_rs2_i,
    output logic        trap_out_o,
    output logic [3:0]  trap_code_o,
    output logic [31:0] trap_pc_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] trap_rs1_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] trap_rs2_o,
    output logic        freeze_pipeline_o
);

    logic next_trap;
    logic [3:0] next_code;

    always_comb begin
        next_trap = type_trap_i || stack_fault_i || div_zero_i || fpu_exception_i ||
                    illegal_opcode_i || call_filter_i || mem_fault_i || addr_align_i ||
                    list_grow_i || list_extend_i || excore_fatal_i;
        if (excore_fatal_i) begin
            next_code = excore_fatal_code_i;
        end else if (type_trap_i) begin
            next_code = PY_TRAP_TYPE;
        end else if (stack_fault_i) begin
            next_code = PY_TRAP_STACK;
        end else if (div_zero_i) begin
            next_code = PY_TRAP_DIV_ZERO;
        end else if (fpu_exception_i) begin
            next_code = PY_TRAP_FPU_EXCEPTION;
        end else if (illegal_opcode_i) begin
            next_code = PY_TRAP_ILLEGAL_OPCODE;
        end else if (call_filter_i) begin
            next_code = PY_TRAP_CALL_FILTER;
        end else if (addr_align_i) begin
            next_code = PY_TRAP_ADDR_ALIGN;
        end else if (mem_fault_i) begin
            next_code = PY_TRAP_MEM_FAULT;
        end else if (list_grow_i) begin
            next_code = PY_TRAP_LIST_GROW;
        end else if (list_extend_i) begin
            next_code = PY_TRAP_LIST_EXTEND;
        end else begin
            next_code = PY_TRAP_NONE;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            trap_out_o <= 1'b0;
            trap_code_o <= PY_TRAP_NONE;
            trap_pc_o <= 32'b0;
            trap_rs1_o <= '0;
            trap_rs2_o <= '0;
        end else if (!trap_out_o && next_trap) begin
            trap_out_o <= 1'b1;
            trap_code_o <= next_code;
            trap_pc_o <= fault_pc_i;
            trap_rs1_o <= fault_rs1_i;
            trap_rs2_o <= fault_rs2_i;
        end
    end

    assign freeze_pipeline_o = trap_out_o || next_trap;

endmodule
