module pycore_div #(
    parameter int LATENCY = 8
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,
    input  logic signed [63:0] dividend,
    input  logic signed [63:0] divisor,
    output logic               busy,
    output logic               valid,
    output logic               div_zero,
    output logic signed [63:0] quotient,
    output logic signed [63:0] remainder
);
    localparam int COUNT_W = (LATENCY > 1) ? $clog2(LATENCY + 1) : 1;

    logic signed [63:0] op_a;
    logic signed [63:0] op_b;
    logic [COUNT_W-1:0] countdown;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            valid     <= 1'b0;
            div_zero  <= 1'b0;
            quotient  <= '0;
            remainder <= '0;
            op_a      <= '0;
            op_b      <= '0;
            countdown <= '0;
        end else begin
            valid    <= 1'b0;
            div_zero <= 1'b0;

            if (start && !busy) begin
                op_a <= dividend;
                op_b <= divisor;
                if (divisor == 0) begin
                    valid     <= 1'b1;
                    div_zero  <= 1'b1;
                    quotient  <= '0;
                    remainder <= '0;
                end else if (LATENCY <= 1) begin
                    valid     <= 1'b1;
                    quotient  <= dividend / divisor;
                    remainder <= dividend % divisor;
                end else begin
                    busy      <= 1'b1;
                    countdown <= LATENCY - 1;
                end
            end else if (busy) begin
                if (countdown == 0) begin
                    busy      <= 1'b0;
                    valid     <= 1'b1;
                    quotient  <= op_a / op_b;
                    remainder <= op_a % op_b;
                end else begin
                    countdown <= countdown - 1'b1;
                end
            end
        end
    end
endmodule
