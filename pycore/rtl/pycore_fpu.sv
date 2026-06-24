`include "pycore_defs.svh"

module pycore_fpu #(
    parameter int LATENCY = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [4:0]  op,
    input  logic [63:0] op_a,
    input  logic [63:0] op_b,
    output logic [63:0] result,
    output logic        exception,
    output logic        done,
    output logic        stall
);

    function automatic logic [63:0] bool_bits(input logic value);
        begin
            bool_bits = {63'b0, value};
        end
    endfunction

    function automatic real abs_real(input real value);
        begin
            abs_real = (value < 0.0) ? -value : value;
        end
    endfunction

    real a_r;
    real b_r;
    real calc_r;
    real div_r;
    logic [63:0] comb_result;
    logic        comb_exception;
    logic [63:0] result_q;
    logic        exception_q;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left;
    logic        busy;

    always_comb begin
        a_r = $bitstoreal(op_a);
        b_r = $bitstoreal(op_b);
        calc_r = 0.0;
        div_r = 0.0;
        comb_result = 64'b0;
        comb_exception = 1'b0;

        unique case (op)
            PY_ALU_ADD: begin
                calc_r = a_r + b_r;
                comb_result = $realtobits(calc_r);
            end
            PY_ALU_SUB: begin
                calc_r = a_r - b_r;
                comb_result = $realtobits(calc_r);
            end
            PY_ALU_MUL: begin
                calc_r = a_r * b_r;
                comb_result = $realtobits(calc_r);
            end
            PY_ALU_TRUE_DIV: begin
                if (b_r == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    calc_r = a_r / b_r;
                    comb_result = $realtobits(calc_r);
                end
            end
            PY_ALU_FLOOR_DIV: begin
                if (b_r == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    div_r = a_r / b_r;
                    calc_r = $floor(div_r);
                    comb_result = $realtobits(calc_r);
                end
            end
            PY_ALU_MOD: begin
                if (b_r == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    div_r = $floor(a_r / b_r);
                    calc_r = a_r - (div_r * b_r);
                    comb_result = $realtobits(calc_r);
                end
            end
            PY_ALU_POWER: begin
                calc_r = a_r ** b_r;
                comb_result = $realtobits(calc_r);
            end
            PY_ALU_NEG: begin
                comb_result = {~op_a[63], op_a[62:0]};
            end
            PY_ALU_POS, PY_ALU_PASS: begin
                comb_result = op_a;
            end
            PY_ALU_NOT: begin
                comb_result = bool_bits((op_a[62:0] == 63'b0));
            end
            PY_ALU_EQ: begin
                comb_result = bool_bits(a_r == b_r);
            end
            PY_ALU_NE: begin
                comb_result = bool_bits(a_r != b_r);
            end
            PY_ALU_LT: begin
                comb_result = bool_bits(a_r < b_r);
            end
            PY_ALU_LE: begin
                comb_result = bool_bits(a_r <= b_r);
            end
            PY_ALU_GT: begin
                comb_result = bool_bits(a_r > b_r);
            end
            PY_ALU_GE: begin
                comb_result = bool_bits(a_r >= b_r);
            end
            default: begin
                comb_exception = 1'b1;
            end
        endcase

        if (abs_real(a_r) > 0.0 && a_r != a_r) begin
            comb_exception = 1'b1;
        end
        if (abs_real(b_r) > 0.0 && b_r != b_r) begin
            comb_exception = 1'b1;
        end
    end

    generate
        if (LATENCY == 0) begin : gen_comb_fpu
            always_comb begin
                result = comb_result;
                exception = start && comb_exception;
                done = start && !comb_exception;
                stall = 1'b0;
            end
        end else begin : gen_seq_fpu
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    busy <= 1'b0;
                    cycles_left <= '0;
                    result_q <= 64'b0;
                    exception_q <= 1'b0;
                end else if (start && !busy) begin
                    busy <= 1'b1;
                    cycles_left <= LATENCY[$bits(cycles_left)-1:0];
                    result_q <= comb_result;
                    exception_q <= comb_exception;
                end else if (busy) begin
                    if (cycles_left <= 1) begin
                        busy <= 1'b0;
                        cycles_left <= '0;
                    end else begin
                        cycles_left <= cycles_left - 1'b1;
                    end
                end
            end

            assign result = result_q;
            assign exception = busy && (cycles_left <= 1) && exception_q;
            assign done = busy && (cycles_left <= 1) && !exception_q;
            assign stall = busy && !done && !exception;
        end
    endgenerate

endmodule
