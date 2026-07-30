`include "pycore_defs.svh"

module pycore_exec #(
    parameter int MUL_LATENCY = 0,
    parameter int DIV_LATENCY = 0,
    parameter int FPU_LATENCY = 0
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
    logic [127:0] complex_a;
    logic [127:0] complex_b;
    logic [63:0] int_result;
    logic [63:0] mul_result;
    logic [63:0] div_result;
    logic [63:0] fpu_result;
    logic [127:0] complex_result;
    logic        int_zero;
    logic        int_overflow;
    logic        mul_done;
    logic        mul_stall;
    logic        div_done;
    logic        div_stall;
    logic        div_zero;
    logic        fpu_done;
    logic        fpu_stall;
    logic        fpu_exception;
    logic        complex_trap;
    logic [4:0]  complex_trap_code;
    logic [63:0] pow_result;
    logic        pow_trap;
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
                    real_bits = value[0] ? 64'h3FF0000000000000 : 64'd0;
                    pycore_value_as_complex = {64'd0, real_bits};
                end
                default: begin
                    // INT (and any unexpected numeric promote path): cast i64→f64.
                    real_bits = $realtobits($itor($signed(value[63:0])));
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
        complex_a = pycore_value_as_complex(rs1_tag, rs1_value_wide);
        complex_b = pycore_value_as_complex(rs2_tag, rs2_value_wide);
    end

    pycore_int_alu int_alu (
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .op_i(alu_op_i),
        .result_o(int_result),
        .zero_flag_o(int_zero),
        .overflow_flag_o(int_overflow)
    );

    pycore_mul #(
        .LATENCY(MUL_LATENCY)
    ) mul_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(valid_i && exec_unit_sel == PY_EXEC_INT && alu_op_i == PY_ALU_MUL && !tag_trap),
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .result_o(mul_result),
        .done_o(mul_done),
        .stall_o(mul_stall)
    );

    pycore_div #(
        .LATENCY(DIV_LATENCY)
    ) div_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(valid_i && exec_unit_sel == PY_EXEC_INT &&
               (alu_op_i == PY_ALU_FLOOR_DIV || alu_op_i == PY_ALU_MOD) && !tag_trap),
        .is_modulo_i(alu_op_i == PY_ALU_MOD),
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .result_o(div_result),
        .div_zero_o(div_zero),
        .done_o(div_done),
        .stall_o(div_stall)
    );

    pycore_fpu #(
        .LATENCY(FPU_LATENCY)
    ) fpu_unit (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .start_i(valid_i && exec_unit_sel == PY_EXEC_FLOAT && !tag_trap),
        .op_i(alu_op_i),
        .op_a_i(unit_a),
        .op_b_i(unit_b),
        .result_o(fpu_result),
        .exception_o(fpu_exception),
        .done_o(fpu_done),
        .stall_o(fpu_stall)
    );

    pycore_complex_alu complex_alu (
        .op_a_i(complex_a),
        .op_b_i(complex_b),
        .op_i(alu_op_i),
        .result_o(complex_result),
        .trap_o(complex_trap),
        .trap_code_o(complex_trap_code)
    );

    always_comb begin
        logic signed [63:0] base;
        logic signed [63:0] exp;
        logic signed [127:0] wide;
        logic signed [63:0] accum;
        int i;

        base = unit_a;
        exp = unit_b;
        accum = 64'sd1;
        wide = 128'sd0;
        pow_result = 64'd1;
        pow_trap = 1'b0;
        if (exp < 0) begin
            pow_trap = 1'b1;
        end else if (exp > 63) begin
            pow_trap = 1'b1;
        end else begin
            for (i = 0; i < 64; i++) begin
                if (i < exp[31:0]) begin
                    wide = accum * base;
                    if (wide[127:64] != {64{wide[63]}}) begin
                        pow_trap = 1'b1;
                    end
                    accum = wide[63:0];
                end
            end
            pow_result = accum;
        end
    end

    always_comb begin
        logic [63:0] selected_value;
        logic [PYCORE_VAL_WIDTH-1:0] wide_value;
        logic        string_cmp_valid;
        logic        string_cmp_eq;

        // Same-tag SHORT_STR / LONG_STR ==/!= : full 128-bit descriptor/
        // payload compare (LONG_STR is interned-descriptor equality).
        string_cmp_valid = valid_i &&
                           ((alu_op_i == PY_ALU_EQ) || (alu_op_i == PY_ALU_NE)) &&
                           (rs1_tag == rs2_tag) &&
                           pycore_is_string_tag(rs1_tag);
        string_cmp_eq = (rs1_value_wide == rs2_value_wide);

        selected_value = 64'b0;
        wide_value = '0;
        stall_o = mul_stall || div_stall || fpu_stall;
        trap_o = valid_i && tag_trap;
        trap_code_o = tag_trap_code;
        result_o = pycore_make_entry(PY_TAG_OBJECT, '0);

        if (string_cmp_valid) begin
            stall_o = 1'b0;
            trap_o = 1'b0;
            trap_code_o = PY_TRAP_NONE;
            result_o = pycore_make_entry(
                PY_TAG_BOOL,
                {{(PYCORE_VAL_WIDTH-1){1'b0}},
                 (alu_op_i == PY_ALU_EQ) ? string_cmp_eq : !string_cmp_eq});
        end else if (string_path_valid_i) begin
            stall_o = 1'b0;
            trap_o = valid_i && string_trap_i;
            trap_code_o = string_trap_code_i;
            result_o = string_result_i;
        end else if (!tag_trap) begin
            unique case (exec_unit_sel)
                PY_EXEC_INT: begin
                    if (alu_op_i == PY_ALU_MUL) begin
                        selected_value = mul_result;
                    end else if (alu_op_i == PY_ALU_FLOOR_DIV || alu_op_i == PY_ALU_MOD) begin
                        selected_value = div_result;
                        if (div_zero) begin
                            trap_o = valid_i;
                            trap_code_o = PY_TRAP_DIV_ZERO;
                        end
                    end else if (alu_op_i == PY_ALU_POWER) begin
                        selected_value = pow_result;
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
                PY_EXEC_FLOAT: begin
                    selected_value = fpu_result;
                    if (fpu_exception) begin
                        trap_o = valid_i;
                        trap_code_o = PY_TRAP_FPU_EXCEPTION;
                    end
                end
                PY_EXEC_COMPLEX: begin
                    selected_value = 64'b0;
                    if (complex_trap) begin
                        trap_o = valid_i;
                        trap_code_o = complex_trap_code;
                    end
                end
                default: begin
                    trap_o = valid_i;
                    trap_code_o = PY_TRAP_TYPE;
                end
            endcase

            if (exec_unit_sel == PY_EXEC_COMPLEX && !trap_o) begin
                result_o = pycore_make_entry(result_tag, complex_result);
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

endmodule
