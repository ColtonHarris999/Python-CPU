module pycore_mul (
    input  logic signed [63:0] a,
    input  logic signed [63:0] b,
    output logic signed [63:0] result
);
    logic signed [127:0] wide_product;

    always_comb begin
        wide_product = a * b;
        result = wide_product[63:0];
    end
endmodule
