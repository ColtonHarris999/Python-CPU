import pycore_types_pkg::*;

module pycore_fetch (
    input  logic [39:0] instr_word,
    input  logic [31:0] ext_accum_in,
    output logic [7:0]  opcode,
    output logic [31:0] arg,
    output logic        is_extended_arg,
    output logic [31:0] ext_accum_out
);
    always_comb begin
        opcode = instr_word[7:0];
        arg = instr_word[39:8];
        is_extended_arg = (opcode == OP_EXTENDED_ARG);
        if (is_extended_arg) begin
            ext_accum_out = (ext_accum_in << 8) | instr_word[39:8];
        end else begin
            ext_accum_out = 32'd0;
        end
    end
endmodule
