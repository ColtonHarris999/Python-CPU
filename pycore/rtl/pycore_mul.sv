`include "pycore_defs.svh"

module pycore_mul #(
    parameter int LATENCY = 0
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        start_i,
    input  logic [63:0] op_a_i,
    input  logic [63:0] op_b_i,
    output logic [63:0] result_o,
    output logic        done_o,
    output logic        stall_o
);

    logic signed [127:0] product;
    logic [63:0]         result_r;
    logic [$clog2((LATENCY < 1) ? 2 : LATENCY + 1)-1:0] cycles_left_r;
    logic                busy_r;

    assign product = $signed(op_a_i) * $signed(op_b_i);

    generate
        if (LATENCY == 0) begin : gen_comb_mul
            always_comb begin
                result_o = product[63:0];
                done_o = start_i;
                stall_o = 1'b0;
            end
        end else begin : gen_seq_mul
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    busy_r <= 1'b0;
                    cycles_left_r <= '0;
                    result_r <= 64'b0;
                end else if (start_i && !busy_r) begin
                    busy_r <= 1'b1;
                    cycles_left_r <= LATENCY[$bits(cycles_left_r)-1:0];
                    result_r <= product[63:0];
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
