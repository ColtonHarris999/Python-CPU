`include "pycore_defs.svh"

// Execute fabric: tag decode, promotion, and the arithmetic units.
//
// Single-cycle (combinational) paths: the integer ALU (add / sub / logic /
// shift / compare), BOOL logic, string compare / short concat, and the
// FPU's combinational operations (negate, truthiness, compares).
//
// Multi-cycle units hold S_EXEC through stall_o until they finish:
//   pycore_mul    INT *      (also the engine behind INT **)
//   pycore_div    INT // %
//   pycore_ipow   INT **
//   pycore_fpu    every FLOAT and COMPLEX arithmetic operation
// Each has a level start_i / one-cycle done_o handshake, and the stall is
// simply "started and not done", so the same units drop into a scoreboard
// later without changing their interfaces.  Cycle counts: docs/alu.md.
module pycore_exec #(
    parameter int MUL_STEP     = 16,
    parameter int DIV_RL       = 2,
    parameter int FPU_MUL_STEP = 14,
    parameter int FPU_DIV_RL   = 2
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        valid_i,
    input  logic [4:0]  alu_op_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs1_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs2_i,
    input  logic        string_path_valid_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] string_result_i,
    input  logic        string_trap_i,
    input  logic [4:0]  string_trap_code_i,
    output logic [PYCORE_ENTRY_WIDTH-1:0] result_o,
    output logic        stall_o,
    output logic        trap_o,
    output logic [4:0]  trap_code_o
);

    logic [3:0] rs1_tag;
    logic [3:0] rs2_tag;
    logic [63:0] rs1_value;
    logic [63:0] rs2_value;
    logic [PYCORE_VAL_WIDTH-1:0] rs1_value_wide;
    logic [PYCORE_VAL_WIDTH-1:0] rs2_value_wide;
    logic [2:0] exec_unit_sel;
    logic       promote_rs1;
    logic       promote_rs2;
    logic [2:0] promote_rs1_mode;
    logic [2:0] promote_rs2_mode;
    logic [3:0] result_tag;
    logic       tag_trap;
    logic [4:0] tag_trap_code;

    logic [63:0] promoted_rs1;
    logic [63:0] promoted_rs2;
    logic [63:0] unit_a;
    logic [63:0] unit_b;
    logic [127:0] fpu_a;
    logic [127:0] fpu_b;
    logic [63:0] int_result;
    logic        int_zero;
    logic        int_overflow;

    // Integer multiplier, shared between INT * and the INT ** sequencer.
    logic        mul_start;
    logic [63:0] mul_a, mul_b;
    logic [63:0] mul_lo, mul_hi;
    logic        mul_done, mul_stall, mul_busy;
    logic        mul_direct_start;
    // Integer divider.
    logic        div_start;
    logic [63:0] div_quot, div_rem;
    logic        div_zero, div_done, div_stall, div_busy;
    // Integer power.
    logic        pow_start;
    logic        pow_mul_start;
    logic [63:0] pow_mul_a, pow_mul_b;
    logic [63:0] pow_result;
    logic        pow_trap, pow_done, pow_stall, pow_busy;
    // FPU (FLOAT and COMPLEX).
    logic        fpu_start;
    logic [127:0] fpu_result;
    logic        fpu_exception, fpu_done, fpu_stall, fpu_busy;

    // 128-bit INT keeps a 64-bit signed fast path: the math leaves operate on
    // value[63:0] and the result_o is sign-/zero-extended back to 128 bits below.
    assign rs1_tag = pycore_get_tag(rs1_i);
    assign rs2_tag = pycore_get_tag(rs2_i);
    assign rs1_value = rs1_i[63:0];
    assign rs2_value = rs2_i[63:0];
    assign rs1_value_wide = pycore_get_val(rs1_i);
    assign rs2_value_wide = pycore_get_val(rs2_i);

    pycore_tag_decode tag_decode (
        .rs1_tag_i(rs1_tag),
        .rs2_tag_i(rs2_tag),
        .alu_op_i(alu_op_i),
        .exec_unit_sel_o(exec_unit_sel),
        .promote_rs1_o(promote_rs1),
        .promote_rs2_o(promote_rs2),
        .promote_rs1_mode_o(promote_rs1_mode),
        .promote_rs2_mode_o(promote_rs2_mode),
        .result_tag_o(result_tag),
        .is_trap_o(tag_trap),
        .trap_code_o(tag_trap_code)
    );

    pycore_promote promote_a (
        .entry_tag_i(rs1_tag),
        .entry_value_i(rs1_value),
        .promote_mode_i(promote_rs1 ? promote_rs1_mode : PY_PROMOTE_NONE),
        .value_out_o(promoted_rs1)
    );

    pycore_promote promote_b (
        .entry_tag_i(rs2_tag),
        .entry_value_i(rs2_value),
        .promote_mode_i(promote_rs2 ? promote_rs2_mode : PY_PROMOTE_NONE),
        .value_out_o(promoted_rs2)
    );

    // Any real-numeric operand of a COMPLEX operation becomes {0.0, real}.
    function automatic [127:0] pycore_value_as_complex(
        input logic [PYCORE_TAG_WIDTH-1:0] tag,
        input logic [PYCORE_VAL_WIDTH-1:0] value
    );
        logic [63:0] real_bits;
        begin
            unique case (tag)
                PY_TAG_COMPLEX: pycore_value_as_complex = value;
                PY_TAG_FLOAT: begin
                    pycore_value_as_complex = {64'd0, value[63:0]};
                end
                PY_TAG_BOOL: begin
                    real_bits = value[0] ? PY_F64_ONE : PY_F64_PZERO;
                    pycore_value_as_complex = {64'd0, real_bits};
                end
                default: begin
                    // INT (and any unexpected numeric promote path): i64 -> f64.
                    real_bits = pycore_i64_to_f64(value[63:0]);
                    pycore_value_as_complex = {64'd0, real_bits};
                end
            endcase
        end
    endfunction

    always_comb begin
        unit_a = promoted_rs1;
        unit_b = promoted_rs2;
        if (exec_unit_sel == PY_EXEC_BOOL) begin
            unit_a = {63'b0, rs1_value[0]};
            unit_b = {63'b0, rs2_value[0]};
        end
        if (exec_unit_sel == PY_EXEC_COMPLEX) begin
            fpu_a = pycore_value_as_complex(rs1_tag, rs1_value_wide);
            fpu_b = pycore_value_as_complex(rs2_tag, rs2_value_wide);
        end else begin
            fpu_a = {64'd0, promoted_rs1};
            fpu_b = {64'd0, promoted_rs2};
        end
    end

    pycore_int_alu int_alu (
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .op_i(alu_op_i),
        .result_o(int_result),
        .zero_flag_o(int_zero),
        .overflow_flag_o(int_overflow)
    );

    // ---- integer multi-cycle units ----
    logic int_route;
    assign int_route = valid_i && (exec_unit_sel == PY_EXEC_INT) && !tag_trap &&
                       !string_path_valid_i;

    assign mul_direct_start = int_route && (alu_op_i == PY_ALU_MUL);
    assign pow_start        = int_route && (alu_op_i == PY_ALU_POWER);
    assign div_start        = int_route &&
                              ((alu_op_i == PY_ALU_FLOOR_DIV) || (alu_op_i == PY_ALU_MOD));

    // The ** sequencer owns the multiplier while it runs.
    assign mul_start = pow_start ? pow_mul_start : mul_direct_start;
    assign mul_a     = pow_start ? pow_mul_a : unit_a;
    assign mul_b     = pow_start ? pow_mul_b : unit_b;

    pycore_mul #(
        .STEP(MUL_STEP)
    ) mul_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(mul_start),
        .op_a_i(mul_a),
        .op_b_i(mul_b),
        .result_o(mul_lo),
        .result_hi_o(mul_hi),
        .done_o(mul_done),
        .stall_o(mul_stall),
        .busy_o(mul_busy)
    );

    pycore_div #(
        .RL(DIV_RL)
    ) div_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(div_start),
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .quot_o(div_quot),
        .rem_o(div_rem),
        .div_zero_o(div_zero),
        .done_o(div_done),
        .stall_o(div_stall),
        .busy_o(div_busy)
    );

    pycore_ipow pow_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(pow_start),
        .base_i(unit_a),
        .exp_i(unit_b),
        .mul_start_o(pow_mul_start),
        .mul_a_o(pow_mul_a),
        .mul_b_o(pow_mul_b),
        .mul_lo_i(mul_lo),
        .mul_hi_i(mul_hi),
        .mul_done_i(mul_done),
        .result_o(pow_result),
        .trap_o(pow_trap),
        .done_o(pow_done),
        .stall_o(pow_stall),
        .busy_o(pow_busy)
    );

    // ---- floating point / complex ----
    assign fpu_start = valid_i && !tag_trap && !string_path_valid_i &&
                       ((exec_unit_sel == PY_EXEC_FLOAT) || (exec_unit_sel == PY_EXEC_COMPLEX));

    pycore_fpu #(
        .MUL_STEP(FPU_MUL_STEP),
        .DIV_RL(FPU_DIV_RL)
    ) fpu_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(fpu_start),
        .op_i(alu_op_i),
        .complex_i(exec_unit_sel == PY_EXEC_COMPLEX),
        .op_a_i(fpu_a),
        .op_b_i(fpu_b),
        .result_o(fpu_result),
        .exception_o(fpu_exception),
        .done_o(fpu_done),
        .stall_o(fpu_stall),
        .busy_o(fpu_busy)
    );

    always_comb begin
        logic [63:0] selected_value;
        logic [PYCORE_VAL_WIDTH-1:0] wide_value;
        logic        string_cmp_valid;
        logic        string_cmp_eq;
        logic        string_ord_valid;
        logic        string_ord_ok;
        logic signed [1:0] string_ord_cmp;
        logic        string_ord_bool;

        logic        string_concat_valid;

        // Same-tag SHORT_STR ==/!= is the inline payload. LONG_STR ==/!=
        // of identical handles (tier 1) or mismatched (hash, nchars)
        // (tier 2) also resolves here; equal-meta distinct addresses go
        // to STRACC SA_CMP (pycore_str_need_payload_cmp).
        string_cmp_valid = valid_i &&
                           ((alu_op_i == PY_ALU_EQ) || (alu_op_i == PY_ALU_NE)) &&
                           (rs1_tag == rs2_tag) &&
                           pycore_is_string_tag(rs1_tag);
        string_cmp_eq = (rs1_value_wide == rs2_value_wide);

        // Mixed-tag string ==/!= is always false under the canonical invariant.
        if (valid_i &&
            ((alu_op_i == PY_ALU_EQ) || (alu_op_i == PY_ALU_NE)) &&
            (rs1_tag != rs2_tag) &&
            pycore_is_string_tag(rs1_tag) && pycore_is_string_tag(rs2_tag)) begin
            string_cmp_valid = 1'b1;
            string_cmp_eq = 1'b0;
        end

        string_concat_valid = valid_i && (alu_op_i == PY_ALU_ADD) &&
                              pycore_str_concat_fits_short(
                                  rs1_tag, rs1_value_wide,
                                  rs2_tag, rs2_value_wide);

        // SHORT_STR lexicographic ordering (<,<=,>,>=).
        string_ord_valid = valid_i &&
                           (rs1_tag == PY_TAG_SHORT_STR) &&
                           (rs2_tag == PY_TAG_SHORT_STR) &&
                           ((alu_op_i == PY_ALU_LT) || (alu_op_i == PY_ALU_LE) ||
                            (alu_op_i == PY_ALU_GT) || (alu_op_i == PY_ALU_GE));
        pycore_short_str_cmp(rs1_value_wide, rs2_value_wide,
                             string_ord_ok, string_ord_cmp);
        unique case (alu_op_i)
            PY_ALU_LT: string_ord_bool = (string_ord_cmp < 0);
            PY_ALU_LE: string_ord_bool = (string_ord_cmp <= 0);
            PY_ALU_GT: string_ord_bool = (string_ord_cmp > 0);
            PY_ALU_GE: string_ord_bool = (string_ord_cmp >= 0);
            default:   string_ord_bool = 1'b0;
        endcase

        selected_value = 64'b0;
        wide_value = '0;
        stall_o = 1'b0;
        trap_o = valid_i && tag_trap;
        trap_code_o = tag_trap_code;
        result_o = pycore_make_entry(PY_TAG_OBJECT, '0);

        if (string_ord_valid) begin
            if (!string_ord_ok) begin
                trap_o = 1'b1;
                trap_code_o = PY_TRAP_TYPE;
            end else begin
                trap_o = 1'b0;
                trap_code_o = PY_TRAP_NONE;
                result_o = pycore_make_entry(
                    PY_TAG_BOOL,
                    {{(PYCORE_VAL_WIDTH-1){1'b0}}, string_ord_bool});
            end
        end else if (string_cmp_valid) begin
            trap_o = 1'b0;
            trap_code_o = PY_TRAP_NONE;
            result_o = pycore_make_entry(
                PY_TAG_BOOL,
                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                 (alu_op_i == PY_ALU_EQ) ? string_cmp_eq : !string_cmp_eq});
        end else if (string_concat_valid) begin
            trap_o = 1'b0;
            trap_code_o = PY_TRAP_NONE;
            result_o = pycore_short_str_concat(rs1_value_wide, rs2_value_wide);
        end else if (string_path_valid_i) begin
            trap_o = valid_i && string_trap_i;
            trap_code_o = string_trap_code_i;
            result_o = string_result_i;
        end else if (!tag_trap) begin
            unique case (exec_unit_sel)
                PY_EXEC_INT: begin
                    if (alu_op_i == PY_ALU_MUL) begin
                        selected_value = mul_lo;
                        stall_o = mul_stall;
                    end else if (alu_op_i == PY_ALU_FLOOR_DIV || alu_op_i == PY_ALU_MOD) begin
                        selected_value = (alu_op_i == PY_ALU_MOD) ? div_rem : div_quot;
                        stall_o = div_stall;
                        if (div_zero) begin
                            trap_o = valid_i;
                            trap_code_o = PY_TRAP_DIV_ZERO;
                        end
                    end else if (alu_op_i == PY_ALU_POWER) begin
                        selected_value = pow_result;
                        stall_o = pow_stall;
                        if (pow_trap) begin
                            trap_o = valid_i;
                            trap_code_o = PY_TRAP_TYPE;
                        end
                    end else begin
                        selected_value = int_result;
                    end
                end
                PY_EXEC_BOOL: begin
                    selected_value = {63'b0, int_result[0]};
                end
                PY_EXEC_FLOAT, PY_EXEC_COMPLEX: begin
                    selected_value = fpu_result[63:0];
                    stall_o = fpu_stall;
                    if (fpu_exception) begin
                        trap_o = valid_i;
                        trap_code_o = PY_TRAP_FPU_EXCEPTION;
                    end
                end
                default: begin
                    trap_o = valid_i;
                    trap_code_o = PY_TRAP_TYPE;
                end
            endcase

            if (exec_unit_sel == PY_EXEC_COMPLEX && !trap_o) begin
                result_o = pycore_make_entry(result_tag, fpu_result);
            end else begin
                if (result_tag == PY_TAG_INT) begin
                    wide_value = {{64{selected_value[63]}}, selected_value};
                end else begin
                    wide_value = {64'b0, selected_value};
                end
                result_o = pycore_make_entry(result_tag, wide_value);
            end
        end
    end

    // Flags and status that the single-instruction FSM does not consume yet
    // (the scoreboard will).
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_ok;
    assign unused_ok = int_zero | int_overflow | mul_busy | div_busy | pow_busy | fpu_busy |
                       mul_done | div_done | pow_done | fpu_done;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
