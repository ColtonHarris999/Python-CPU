`include "pycore_defs.svh"

module pycore_div #(
    parameter int LATENCY = 0
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic        is_modulo_i,
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,
    output logic        div_zero_o,
    output logic        done_o,
    output logic        stall_o
);

    function automatic logic signed [63:0] floor_quotient(
        input logic signed [63:0] lhs,
        input logic signed [63:0] rhs
    );
        logic signed [63:0] q;
        logic signed [63:0] r;
        begin
            q = lhs / rhs;
            r = lhs % rhs;
            if ((r != 0) && ((r > 0 && rhs < 0) || (r < 0 && rhs > 0))) begin
                q = q - 1;
            end
            floor_quotient = q;
        end
    endfunction

    function automatic logic signed [63:0] floor_remainder(
        input logic signed [63:0] lhs,
        input logic signed [63:0] rhs
    );
        logic signed [63:0] q;
        begin
            q = floor_quotient(lhs, rhs);
            floor_remainder = lhs - (q * rhs);
        end
    endfunction

    logic signed [63:0] a_s;
    logic signed [63:0] b_s;
    logic [63:0]        comb_result;
    logic [63:0]        result_r;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left_r;
    logic               busy_r;

    assign a_s = op_a_i;
    assign b_s = op_b_i;
    assign div_zero_o = start_i && (op_b_i == 64'b0);

    always_comb begin
        if (op_b_i == 64'b0) begin
            comb_result = 64'b0;
        end else if (is_modulo_i) begin
            comb_result = floor_remainder(a_s, b_s);
        end else begin
            comb_result = floor_quotient(a_s, b_s);
        end
    end

    generate
        if (LATENCY == 0) begin : gen_comb_div
            always_comb begin
                result_o = comb_result;
                done_o = start_i && !div_zero_o;
                stall_o = 1'b0;
            end
        end else begin : gen_seq_div
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    busy_r <= 1'b0;
                    cycles_left_r <= '0;
                    result_r <= 64'b0;
                end else if (start_i && !busy_r && !div_zero_o) begin
                    busy_r <= 1'b1;
                    cycles_left_r <= LATENCY[$bits(cycles_left_r)-1:0];
                    result_r <= comb_result;
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
            assign done_o = busy_r && (cycles_left_r <= 1);
            assign stall_o = busy_r && !done_o;
        end
    endgenerate

endmodule
