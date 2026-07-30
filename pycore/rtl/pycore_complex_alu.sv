`include "pycore_defs.svh"

// Combinational complex ALU. Operands are already COMPLEX-normalized
// (real in [63:0], imag in [127:64] as IEEE754 binary64 bit patterns).
module pycore_complex_alu (
    input  logic [127:0] op_a_i,
    input  logic [127:0] op_b_i,
    input  logic [4:0]   op_i,
    output logic [127:0] result_o,
    output logic         trap_o,
    output logic [4:0]   trap_code_o
);
    real ar, ai, br, bi, rr, ri, denom;

    always_comb begin
        ar = $bitstoreal(op_a_i[63:0]);
        ai = $bitstoreal(op_a_i[127:64]);
        br = $bitstoreal(op_b_i[63:0]);
        bi = $bitstoreal(op_b_i[127:64]);
        rr = 0.0;
        ri = 0.0;
        denom = 0.0;
        trap_o = 1'b0;
        trap_code_o = PY_TRAP_NONE;
        result_o = 128'b0;

        unique case (op_i)
            PY_ALU_ADD: begin
                rr = ar + br;
                ri = ai + bi;
                result_o = {$realtobits(ri), $realtobits(rr)};
            end
            PY_ALU_SUB: begin
                rr = ar - br;
                ri = ai - bi;
                result_o = {$realtobits(ri), $realtobits(rr)};
            end
            PY_ALU_MUL: begin
                rr = (ar * br) - (ai * bi);
                ri = (ar * bi) + (ai * br);
                result_o = {$realtobits(ri), $realtobits(rr)};
            end
            PY_ALU_TRUE_DIV: begin
                denom = (br * br) + (bi * bi);
                if (denom == 0.0) begin
                    trap_o = 1'b1;
                    trap_code_o = PY_TRAP_DIV_ZERO;
                end else begin
                    rr = ((ar * br) + (ai * bi)) / denom;
                    ri = ((ai * br) - (ar * bi)) / denom;
                    result_o = {$realtobits(ri), $realtobits(rr)};
                end
            end
            PY_ALU_NEG: begin
                rr = -ar;
                ri = -ai;
                result_o = {$realtobits(ri), $realtobits(rr)};
            end
            PY_ALU_POS: begin
                result_o = op_a_i;
            end
            PY_ALU_EQ: begin
                result_o = {127'b0, (op_a_i == op_b_i)};
            end
            PY_ALU_NE: begin
                result_o = {127'b0, (op_a_i != op_b_i)};
            end
            PY_ALU_NOT: begin
                // Truthiness: nonzero real or imag → True, then invert.
                result_o = {127'b0,
                    !((op_a_i[62:0] != 63'b0) || (op_a_i[126:64] != 63'b0))};
            end
            default: begin
                trap_o = 1'b1;
                trap_code_o = PY_TRAP_TYPE;
            end
        endcase
    end
endmodule
