`include "pycore_defs.svh"

module pycore_div #(
    parameter int LATENCY = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        is_modulo,
    input  logic [63:0] op_a,
    input  logic [63:0] op_b,
    output logic [63:0] result,
    output logic        div_zero,
    output logic        done,
    output logic        stall
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
    logic [63:0]        result_q;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left;
    logic               busy;

    assign a_s = op_a;
    assign b_s = op_b;
    assign div_zero = start && (op_b == 64'b0);

    always_comb begin
        if (op_b == 64'b0) begin
            comb_result = 64'b0;
        end else if (is_modulo) begin
            comb_result = floor_remainder(a_s, b_s);
        end else begin
            comb_result = floor_quotient(a_s, b_s);
        end
    end

    generate
        if (LATENCY == 0) begin : gen_comb_div
            always_comb begin
                result = comb_result;
                done = start && !div_zero;
                stall = 1'b0;
            end
        end else begin : gen_seq_div
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    busy <= 1'b0;
                    cycles_left <= '0;
                    result_q <= 64'b0;
                end else if (start && !busy && !div_zero) begin
                    busy <= 1'b1;
                    cycles_left <= LATENCY[$bits(cycles_left)-1:0];
                    result_q <= comb_result;
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
            assign done = busy && (cycles_left <= 1);
            assign stall = busy && !done;
        end
    endgenerate

endmodule
