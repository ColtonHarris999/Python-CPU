`include "pycore_defs.svh"

module pycore_promote (
    input  logic [2:0] entry_tag,
    input  logic [63:0] entry_value,
    input  logic [1:0] promote_mode,
    output logic [63:0] value_out
);

    always_comb begin
        unique case (promote_mode)
            PY_PROMOTE_NONE: begin
                value_out = entry_value;
            end
            PY_PROMOTE_INT_TO_FLOAT: begin
                value_out = $realtobits($itor($signed(entry_value)));
            end
            PY_PROMOTE_BOOL_TO_INT: begin
                value_out = {63'b0, entry_value[0]};
            end
            PY_PROMOTE_BOOL_TO_FLOAT: begin
                value_out = entry_value[0] ? 64'h3ff0_0000_0000_0000 : 64'h0000_0000_0000_0000;
            end
            default: begin
                value_out = entry_value;
            end
        endcase
    end

    // The tag decode fabric selects promotion modes. Keep this assertion local
    // to catch integration bugs without coupling conversion to result tagging.
    always_comb begin
        if (promote_mode == PY_PROMOTE_INT_TO_FLOAT) begin
            assert (entry_tag == PY_TAG_INT);
        end else if (promote_mode == PY_PROMOTE_BOOL_TO_INT ||
                     promote_mode == PY_PROMOTE_BOOL_TO_FLOAT) begin
            assert (entry_tag == PY_TAG_BOOL);
        end
    end

endmodule
