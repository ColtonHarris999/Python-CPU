`include "pycore_defs.svh"

module pycore_fetch (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic        flush,
    input  logic        branch_taken,
    input  logic [31:0] branch_target,
    output logic [31:0] imem_addr,
    input  logic [39:0] imem_rdata,
    output logic        instr_valid,
    output logic [7:0]  opcode,
    output logic [31:0] arg,
    output logic [31:0] pc
);

    logic [31:0] pc_q;
    logic [31:0] arg_prefix_q;
    logic        have_prefix_q;

    function automatic logic [3:0] cache_count(input logic [7:0] op);
        begin
            unique case (op)
                // CPython inline caches vary by opcode. Unsupported cache-heavy
                // opcodes trap in decode; supported fast-path opcodes have no
                // architectural cache slots in the stripped stream.
                default: cache_count = 4'd0;
            endcase
        end
    endfunction

    assign imem_addr = pc_q;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0] fetched_opcode;
        logic [31:0] fetched_arg;
        logic [31:0] folded_arg;
        logic [3:0] cache_slots;

        if (!rst_n) begin
            pc_q <= 32'b0;
            arg_prefix_q <= 32'b0;
            have_prefix_q <= 1'b0;
            instr_valid <= 1'b0;
            opcode <= 8'b0;
            arg <= 32'b0;
            pc <= 32'b0;
        end else if (!stall) begin
            instr_valid <= 1'b0;
            opcode <= 8'b0;
            arg <= 32'b0;
            pc <= 32'b0;

            if (flush) begin
                have_prefix_q <= 1'b0;
                arg_prefix_q <= 32'b0;
            end else if (branch_taken) begin
                pc_q <= branch_target;
                have_prefix_q <= 1'b0;
                arg_prefix_q <= 32'b0;
            end else begin
                fetched_opcode = imem_rdata[7:0];
                fetched_arg = imem_rdata[39:8];
                folded_arg = have_prefix_q ? ((arg_prefix_q << 8) | fetched_arg[7:0]) : fetched_arg;
                cache_slots = cache_count(fetched_opcode);

                if (fetched_opcode == PY_OP_CACHE) begin
                    pc_q <= pc_q + 1;
                end else if (fetched_opcode == PY_OP_EXTENDED_ARG) begin
                    arg_prefix_q <= folded_arg;
                    have_prefix_q <= 1'b1;
                    pc_q <= pc_q + 1;
                end else begin
                    instr_valid <= 1'b1;
                    opcode <= fetched_opcode;
                    arg <= folded_arg;
                    pc <= pc_q;
                    have_prefix_q <= 1'b0;
                    arg_prefix_q <= 32'b0;
                    pc_q <= pc_q + 1 + cache_slots;
                end
            end
        end
    end

endmodule
