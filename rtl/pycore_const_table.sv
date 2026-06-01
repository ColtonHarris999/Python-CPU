module pycore_const_table #(
    parameter int CONST_DEPTH = 256,
    parameter int ENTRY_W = 66,
    parameter string CONST_HEX = "programs/pycore_consts.hex"
) (
    input  logic [$clog2(CONST_DEPTH)-1:0] idx,
    output logic [ENTRY_W-1:0]             entry
);
    logic [ENTRY_W-1:0] const_mem [0:CONST_DEPTH-1];

    initial begin
        $readmemh(CONST_HEX, const_mem);
    end

    always_comb begin
        entry = const_mem[idx];
    end
endmodule
