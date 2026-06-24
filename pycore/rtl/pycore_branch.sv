`include "pycore_defs.svh"

module pycore_branch (
    input  logic [7:0]  opcode,
    input  logic [31:0] pc,
    input  logic [31:0] arg,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] tos_entry,
    output logic        take_branch,
    output logic [31:0] branch_target,
    output logic        trap,
    output logic [3:0]  trap_code
);

    logic [2:0] tag;
    logic [PYCORE_VAL_WIDTH-1:0] value;
    logic truthy;

    assign tag = pycore_get_tag(tos_entry);
    assign value = pycore_get_val(tos_entry);

    always_comb begin
        truthy = 1'b0;
        trap = 1'b0;
        trap_code = PY_TRAP_NONE;

        unique case (tag)
            PY_TAG_BOOL: begin
                truthy = value[0];
            end
            PY_TAG_INT: begin
                truthy = value != 64'b0;
            end
            PY_TAG_FLOAT: begin
                truthy = value[62:0] != 63'b0;
            end
            default: begin
                truthy = 1'b0;
                trap = 1'b1;
                trap_code = PY_TRAP_TYPE;
            end
        endcase
    end

    always_comb begin
        take_branch = 1'b0;
        branch_target = pc;

        unique case (opcode)
            PY_OP_JUMP_FORWARD: begin
                take_branch = 1'b1;
                branch_target = pc + arg;
            end
            PY_OP_JUMP_BACKWARD: begin
                take_branch = 1'b1;
                branch_target = pc - arg;
            end
            PY_OP_POP_JUMP_IF_TRUE: begin
                take_branch = truthy && !trap;
                branch_target = arg;
            end
            PY_OP_POP_JUMP_IF_FALSE: begin
                take_branch = !truthy && !trap;
                branch_target = arg;
            end
            default: begin
                take_branch = 1'b0;
                branch_target = pc;
            end
        endcase
    end

endmodule
