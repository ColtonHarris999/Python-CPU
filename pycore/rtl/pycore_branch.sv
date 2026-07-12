`include "pycore_defs.svh"

module pycore_branch (
    input  logic [7:0]  opcode_i,
    input  logic [31:0] pc_i,
    input  logic [31:0] arg_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] tos_entry_i,
    output logic        take_branch_o,
    output logic [31:0] branch_target_o,
    output logic        trap_o,
    output logic [3:0]  trap_code_o
);

    logic [3:0] tag;
    logic [PYCORE_VAL_WIDTH-1:0] value;
    logic truthy;
    logic [7:0] n_cache;

    assign tag = pycore_get_tag(tos_entry_i);
    assign value = pycore_get_val(tos_entry_i);

    // Relative-jump target = pc + 1 + n_cache ± arg  (CPython 3.14 unit math;
    // slot index == code-unit index after 1:1 transcoding).
    always_comb begin
        unique case (opcode_i)
            PY_OP_JUMP_FORWARD:      n_cache = PY_CACHE_JUMP_FORWARD;
            PY_OP_JUMP_BACKWARD:     n_cache = PY_CACHE_JUMP_BACKWARD;
            PY_OP_POP_JUMP_IF_TRUE:  n_cache = PY_CACHE_POP_JUMP_IF_TRUE;
            PY_OP_POP_JUMP_IF_FALSE: n_cache = PY_CACHE_POP_JUMP_IF_FALSE;
            default:                 n_cache = 8'd0;
        endcase
    end

    always_comb begin
        truthy = 1'b0;
        trap_o = 1'b0;
        trap_code_o = PY_TRAP_NONE;

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
                trap_o = 1'b1;
                trap_code_o = PY_TRAP_TYPE;
            end
        endcase
    end

    always_comb begin
        take_branch_o = 1'b0;
        branch_target_o = pc_i;

        unique case (opcode_i)
            PY_OP_JUMP_FORWARD: begin
                take_branch_o = 1'b1;
                branch_target_o = pc_i + 32'd1 + {24'b0, n_cache} + arg_i;
            end
            PY_OP_JUMP_BACKWARD: begin
                take_branch_o = 1'b1;
                branch_target_o = pc_i + 32'd1 + {24'b0, n_cache} - arg_i;
            end
            PY_OP_POP_JUMP_IF_TRUE: begin
                take_branch_o = truthy && !trap_o;
                branch_target_o = pc_i + 32'd1 + {24'b0, n_cache} + arg_i;
            end
            PY_OP_POP_JUMP_IF_FALSE: begin
                take_branch_o = !truthy && !trap_o;
                branch_target_o = pc_i + 32'd1 + {24'b0, n_cache} + arg_i;
            end
            default: begin
                take_branch_o = 1'b0;
                branch_target_o = pc_i;
            end
        endcase
    end

endmodule
