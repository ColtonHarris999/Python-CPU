import pycore_types_pkg::*;

module pycore_branch (
    input  logic [7:0]  opcode,
    input  logic [31:0] arg,
    input  logic [31:0] pc,
    input  logic [65:0] tos_entry,
    output logic        take_branch,
    output logic [31:0] branch_target,
    output logic        pop_tos,
    output logic        trap,
    output logic [3:0]  trap_code
);
    logic tos_truthy;
    logic tos_valid_truth;

    always_comb begin
        take_branch  = 1'b0;
        branch_target = pc + 32'd1;
        pop_tos      = 1'b0;
        trap         = 1'b0;
        trap_code    = TRAP_NONE;
        tos_truthy   = 1'b0;
        tos_valid_truth = 1'b0;

        if (tos_entry[65:64] == TAG_BOOL) begin
            tos_truthy = tos_entry[0];
            tos_valid_truth = 1'b1;
        end else if (tos_entry[65:64] == TAG_INT) begin
            tos_truthy = (tos_entry[63:0] != 64'd0);
            tos_valid_truth = 1'b1;
        end

        unique case (opcode)
            OP_JUMP_FORWARD: begin
                take_branch = 1'b1;
                branch_target = pc + arg;
            end

            OP_JUMP_BACKWARD: begin
                take_branch = 1'b1;
                branch_target = pc - arg;
            end

            OP_POP_JUMP_FORWARD_IF_TRUE: begin
                pop_tos = 1'b1;
                if (tos_valid_truth) begin
                    take_branch = tos_truthy;
                    branch_target = pc + arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            OP_POP_JUMP_FORWARD_IF_FALSE: begin
                pop_tos = 1'b1;
                if (tos_valid_truth) begin
                    take_branch = !tos_truthy;
                    branch_target = pc + arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            OP_POP_JUMP_BACKWARD_IF_TRUE: begin
                pop_tos = 1'b1;
                if (tos_valid_truth) begin
                    take_branch = tos_truthy;
                    branch_target = pc - arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            OP_POP_JUMP_BACKWARD_IF_FALSE: begin
                pop_tos = 1'b1;
                if (tos_valid_truth) begin
                    take_branch = !tos_truthy;
                    branch_target = pc - arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            OP_JUMP_IF_TRUE_OR_POP: begin
                if (tos_valid_truth) begin
                    take_branch = tos_truthy;
                    if (!tos_truthy) begin
                        pop_tos = 1'b1;
                    end
                    branch_target = pc + arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            OP_JUMP_IF_FALSE_OR_POP: begin
                if (tos_valid_truth) begin
                    take_branch = !tos_truthy;
                    if (tos_truthy) begin
                        pop_tos = 1'b1;
                    end
                    branch_target = pc + arg;
                end else begin
                    trap = 1'b1;
                    trap_code = TRAP_TYPE;
                end
            end

            default: begin
            end
        endcase
    end
endmodule
