`include "pycore_defs.svh"

module pycore_fpu #(
    parameter int LATENCY = 0
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [4:0]  op_i,
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,
    output logic        exception_o,
    output logic        done_o,
    output logic        stall_o
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

    real a_real;
    real b_real;
    real calc_real;
    real div_real;
    logic [63:0] comb_result;
    logic        comb_exception;
    logic [63:0] result_r;
    logic        exception_r;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left_r;
    logic        busy_r;

    always_comb begin
        a_real = $bitstoreal(op_a_i);
        b_real = $bitstoreal(op_b_i);
        calc_real = 0.0;
        div_real = 0.0;
        comb_result = 64'b0;
        comb_exception = 1'b0;

        unique case (op_i)
            PY_ALU_ADD: begin
                calc_real = a_real + b_real;
                comb_result = $realtobits(calc_real);
            end
            PY_ALU_SUB: begin
                calc_real = a_real - b_real;
                comb_result = $realtobits(calc_real);
            end
            PY_ALU_MUL: begin
                calc_real = a_real * b_real;
                comb_result = $realtobits(calc_real);
            end
            PY_ALU_TRUE_DIV: begin
                if (b_real == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    calc_real = a_real / b_real;
                    comb_result = $realtobits(calc_real);
                end
            end
            PY_ALU_FLOOR_DIV: begin
                if (b_real == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    div_real = a_real / b_real;
                    calc_real = $floor(div_real);
                    comb_result = $realtobits(calc_real);
                end
            end
            PY_ALU_MOD: begin
                if (b_real == 0.0) begin
                    comb_exception = 1'b1;
                end else begin
                    div_real = $floor(a_real / b_real);
                    calc_real = a_real - (div_real * b_real);
                    comb_result = $realtobits(calc_real);
                end
            end
            PY_ALU_POWER: begin
                calc_real = a_real ** b_real;
                comb_result = $realtobits(calc_real);
            end
            PY_ALU_NEG: begin
                comb_result = {~op_a_i[63], op_a_i[62:0]};
            end
            PY_ALU_POS, PY_ALU_PASS: begin
                comb_result = op_a_i;
            end
            PY_ALU_NOT: begin
                comb_result = bool_bits((op_a_i[62:0] == 63'b0));
            end
            PY_ALU_EQ: begin
                comb_result = bool_bits(a_real == b_real);
            end
            PY_ALU_NE: begin
                comb_result = bool_bits(a_real != b_real);
            end
            PY_ALU_LT: begin
                comb_result = bool_bits(a_real < b_real);
            end
            PY_ALU_LE: begin
                comb_result = bool_bits(a_real <= b_real);
            end
            PY_ALU_GT: begin
                comb_result = bool_bits(a_real > b_real);
            end
            PY_ALU_GE: begin
                comb_result = bool_bits(a_real >= b_real);
            end
            default: begin
                comb_exception = 1'b1;
            end
        endcase

        if (abs_real(a_real) > 0.0 && a_real != a_real) begin
            comb_exception = 1'b1;
        end
        if (abs_real(b_real) > 0.0 && b_real != b_real) begin
            comb_exception = 1'b1;
        end
    end

    generate
        if (LATENCY == 0) begin : gen_comb_fpu
            always_comb begin
                result_o = comb_result;
                exception_o = start_i && comb_exception;
                done_o = start_i && !comb_exception;
                stall_o = 1'b0;
            end
        end else begin : gen_seq_fpu
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    busy_r <= 1'b0;
                    cycles_left_r <= '0;
                    result_r <= 64'b0;
                    exception_r <= 1'b0;
                end else if (start_i && !busy_r) begin
                    busy_r <= 1'b1;
                    cycles_left_r <= LATENCY[$bits(cycles_left_r)-1:0];
                    result_r <= comb_result;
                    exception_r <= comb_exception;
                end else if (busy_r) begin
                    if (cycles_left_r <= 1) begin
                        busy_r <= 1'b0;
                        cycles_left_r <= '0;
                    end else begin
                        cycles_left_r <= cycles_left_r - 1'b1;
                    end
                end
            end

            assign result_o = result_r;
            assign exception_o = busy_r && (cycles_left_r <= 1) && exception_r;
            assign done_o = busy_r && (cycles_left_r <= 1) && !exception_r;
            assign stall_o = busy_r && !done_o && !exception_o;
        end
    endgenerate

endmodule
