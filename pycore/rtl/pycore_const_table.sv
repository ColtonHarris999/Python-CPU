`include "pycore_defs.svh"

module pycore_const_table #(
    parameter int CONST_DEPTH = 256,
    parameter string CONST_HEX = "pycore/programs/consts.hex"
) (
    input  logic [$clog2(CONST_DEPTH)-1:0] const_idx_i,
    output logic [PYCORE_ENTRY_WIDTH-1:0] const_entry_o
);

    logic [PYCORE_ENTRY_WIDTH-1:0] const_mem [0:CONST_DEPTH-1];

    initial begin
        int i;
        for (i = 0; i < CONST_DEPTH; i++) begin
            const_mem[i] = pycore_make_entry(PY_TAG_UNINIT, '0);
        end
        $readmemh(CONST_HEX, const_mem);
    end

    assign const_entry_o = const_mem[const_idx_i];

endmodule
