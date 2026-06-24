`include "pycore_defs.svh"

module pycore_exec #(
    parameter int MUL_LATENCY = 0,
    parameter int DIV_LATENCY = 0,
    parameter int FPU_LATENCY = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid,
    input  logic [4:0]  alu_op,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs1,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs2,
    output logic [PYCORE_ENTRY_WIDTH-1:0] result,
    output logic        stall,
    output logic        trap,
    output logic [3:0]  trap_code
);

    logic [2:0] rs1_tag;
    logic [2:0] rs2_tag;
    logic [63:0] rs1_value;
    logic [63:0] rs2_value;
    logic [1:0] exec_unit_sel;
    logic       promote_rs1;
    logic       promote_rs2;
    logic [1:0] promote_rs1_mode;
    logic [1:0] promote_rs2_mode;
    logic [2:0] result_tag;
    logic       tag_trap;
    logic [3:0] tag_trap_code;

    logic [63:0] promoted_rs1;
    logic [63:0] promoted_rs2;
    logic [63:0] unit_a;
    logic [63:0] unit_b;
    logic [63:0] int_result;
    logic [63:0] mul_result;
    logic [63:0] div_result;
    logic [63:0] fpu_result;
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
    logic [63:0] pow_result;
    logic        pow_trap;

    // 128-bit INT keeps a 64-bit signed fast path: the math leaves operate on
    // value[63:0] and the result is sign-/zero-extended back to 128 bits below.
    assign rs1_tag = pycore_get_tag(rs1);
    assign rs2_tag = pycore_get_tag(rs2);
    assign rs1_value = rs1[63:0];
    assign rs2_value = rs2[63:0];

    pycore_tag_decode tag_decode (
        .rs1_tag(rs1_tag),
        .rs2_tag(rs2_tag),
        .alu_op(alu_op),
        .exec_unit_sel(exec_unit_sel),
        .promote_rs1(promote_rs1),
        .promote_rs2(promote_rs2),
        .promote_rs1_mode(promote_rs1_mode),
        .promote_rs2_mode(promote_rs2_mode),
        .result_tag(result_tag),
        .is_trap(tag_trap),
        .trap_code(tag_trap_code)
    );

    pycore_promote promote_a (
        .entry_tag(rs1_tag),
        .entry_value(rs1_value),
        .promote_mode(promote_rs1 ? promote_rs1_mode : PY_PROMOTE_NONE),
        .value_out(promoted_rs1)
    );

    pycore_promote promote_b (
        .entry_tag(rs2_tag),
        .entry_value(rs2_value),
        .promote_mode(promote_rs2 ? promote_rs2_mode : PY_PROMOTE_NONE),
        .value_out(promoted_rs2)
    );

    always_comb begin
        unit_a = promoted_rs1;
        unit_b = promoted_rs2;
        if (exec_unit_sel == PY_EXEC_BOOL) begin
            unit_a = {63'b0, rs1_value[0]};
            unit_b = {63'b0, rs2_value[0]};
        end
    end

    pycore_int_alu int_alu (
        .op_a(unit_a),
        .op_b(unit_b),
        .op(alu_op),
        .result(int_result),
        .zero_flag(int_zero),
        .overflow_flag(int_overflow)
    );

    pycore_mul #(
        .LATENCY(MUL_LATENCY)
    ) mul_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(valid && exec_unit_sel == PY_EXEC_INT && alu_op == PY_ALU_MUL && !tag_trap),
        .op_a(unit_a),
        .op_b(unit_b),
        .result(mul_result),
        .done(mul_done),
        .stall(mul_stall)
    );

    pycore_div #(
        .LATENCY(DIV_LATENCY)
    ) div_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(valid && exec_unit_sel == PY_EXEC_INT &&
               (alu_op == PY_ALU_FLOOR_DIV || alu_op == PY_ALU_MOD) && !tag_trap),
        .is_modulo(alu_op == PY_ALU_MOD),
        .op_a(unit_a),
        .op_b(unit_b),
        .result(div_result),
        .div_zero(div_zero),
        .done(div_done),
        .stall(div_stall)
    );

    pycore_fpu #(
        .LATENCY(FPU_LATENCY)
    ) fpu_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(valid && exec_unit_sel == PY_EXEC_FLOAT && !tag_trap),
        .op(alu_op),
        .op_a(unit_a),
        .op_b(unit_b),
        .result(fpu_result),
        .exception(fpu_exception),
        .done(fpu_done),
        .stall(fpu_stall)
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

        selected_value = 64'b0;
        stall = mul_stall || div_stall || fpu_stall;
        trap = valid && tag_trap;
        trap_code = tag_trap_code;

        if (!tag_trap) begin
            unique case (exec_unit_sel)
                PY_EXEC_INT: begin
                    if (alu_op == PY_ALU_MUL) begin
                        selected_value = mul_result;
                    end else if (alu_op == PY_ALU_FLOOR_DIV || alu_op == PY_ALU_MOD) begin
                        selected_value = div_result;
                        if (div_zero) begin
                            trap = valid;
                            trap_code = PY_TRAP_DIV_ZERO;
                        end
                    end else if (alu_op == PY_ALU_POWER) begin
                        selected_value = pow_result;
                        if (pow_trap) begin
                            trap = valid;
                            trap_code = PY_TRAP_TYPE;
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
                        trap = valid;
                        trap_code = PY_TRAP_FPU_EXCEPTION;
                    end
                end
                default: begin
                    trap = valid;
                    trap_code = PY_TRAP_TYPE;
                end
            endcase
        end

        // Extend the 64-bit unit result up to the 128-bit value field. INT is
        // sign-extended so the architectural upper bits stay consistent with the
        // documented fast-path semantics; every other tag zero-extends.
        if (result_tag == PY_TAG_INT) begin
            wide_value = {{64{selected_value[63]}}, selected_value};
        end else begin
            wide_value = {64'b0, selected_value};
        end

        result = pycore_make_entry(result_tag, wide_value);
    end

endmodule
