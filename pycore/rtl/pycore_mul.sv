`include "pycore_defs.svh"

module pycore_mul #(
    parameter int LATENCY = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] op_a,
    input  logic [63:0] op_b,
    output logic [63:0] result,
    output logic        done,
    output logic        stall
);

    logic signed [127:0] product;
    logic [63:0]         result_q;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left;
    logic                busy;

    assign product = $signed(op_a) * $signed(op_b);

    generate
        if (LATENCY == 0) begin : gen_comb_mul
            always_comb begin
                result = product[63:0];
                done = start;
                stall = 1'b0;
            end
        end else begin : gen_seq_mul
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    busy <= 1'b0;
                    cycles_left <= '0;
                    result_q <= 64'b0;
                end else if (start && !busy) begin
                    busy <= 1'b1;
                    cycles_left <= LATENCY[$bits(cycles_left)-1:0];
                    result_q <= product[63:0];
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
