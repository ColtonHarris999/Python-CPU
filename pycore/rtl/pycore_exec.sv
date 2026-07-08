`include "pycore_defs.svh"

module pycore_exec #(
    parameter int MUL_LATENCY = 0,
    parameter int DIV_LATENCY = 0,
    parameter int FPU_LATENCY = 0,
    parameter int STRING_MEM_BYTES = 65536,
    parameter int STRING_MAX_LEN = 4096,
    parameter longint unsigned STRING_RUNTIME_BASE = 64'd16384,
    parameter string STRING_HEX = "pycore/programs/string_mem.hex"
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        valid_i,
    input  logic [4:0]  alu_op_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs1_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] rs2_i,
    output logic [PYCORE_ENTRY_WIDTH-1:0] result_o,
    output logic        stall_o,
    output logic        trap_o,
    output logic [3:0]  trap_code_o
);

    logic [2:0] rs1_tag;
    logic [2:0] rs2_tag;
    logic [63:0] rs1_value;
    logic [63:0] rs2_value;
    logic [PYCORE_VAL_WIDTH-1:0] rs1_value_wide;
    logic [PYCORE_VAL_WIDTH-1:0] rs2_value_wide;
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
    logic [7:0] string_mem [0:STRING_MEM_BYTES-1];
    logic [63:0] string_heap_alloc_r;
    logic [63:0] string_heap_alloc_d;
    logic [PYCORE_ENTRY_WIDTH-1:0] string_result_entry;
    logic string_path_valid;
    logic string_path_trap;
    logic [3:0] string_path_trap_code;
    logic string_store_fire;
    longint unsigned string_lhs_len;
    longint unsigned string_rhs_len;
    longint unsigned string_concat_len;
    longint unsigned string_lhs_addr;
    longint unsigned string_rhs_addr;
    longint unsigned string_dst_addr;
    logic [119:0] string_short_payload;
    localparam logic [63:0] STRING_MEM_BYTES_U64 = STRING_MEM_BYTES;
    localparam logic [63:0] STRING_MAX_LEN_U64 = STRING_MAX_LEN;
    localparam logic [63:0] STRING_RUNTIME_BASE_U64 = STRING_RUNTIME_BASE[63:0];

    // 128-bit INT keeps a 64-bit signed fast path: the math leaves operate on
    // value[63:0] and the result_o is sign-/zero-extended back to 128 bits below.
    assign rs1_tag = pycore_get_tag(rs1_i);
    assign rs2_tag = pycore_get_tag(rs2_i);
    assign rs1_value = rs1_i[63:0];
    assign rs2_value = rs2_i[63:0];
    assign rs1_value_wide = pycore_get_val(rs1_i);
    assign rs2_value_wide = pycore_get_val(rs2_i);

    initial begin
        int i;
        for (i = 0; i < STRING_MEM_BYTES; i++) begin
            string_mem[i] = 8'h00;
        end
        $readmemh(STRING_HEX, string_mem);
    end

    function automatic logic [7:0] string_operand_byte(
        input logic [2:0] tag,
        input logic [PYCORE_VAL_WIDTH-1:0] value,
        input longint unsigned idx
    );
        int unsigned mem_idx;
        begin
            if (tag == PY_TAG_SHORT_STR) begin
                string_operand_byte = pycore_short_str_byte(value, idx[3:0]);
            end else begin
                mem_idx = int'(pycore_long_str_addr(value) + idx);
                string_operand_byte = string_mem[mem_idx];
            end
        end
    endfunction

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

    always_comb begin
        unit_a = promoted_rs1;
        unit_b = promoted_rs2;
        if (exec_unit_sel == PY_EXEC_BOOL) begin
            unit_a = {63'b0, rs1_value[0]};
            unit_b = {63'b0, rs2_value[0]};
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
        int i;
        logic [7:0] byte_value;
        logic [63:0] lhs_addr_plus_len;
        logic [63:0] rhs_addr_plus_len;
        logic [63:0] dst_addr_plus_len;
        logic [63:0] concat_len_u64;
        logic [63:0] lhs_len_u64;
        logic [63:0] rhs_len_u64;

        string_path_valid = valid_i && (alu_op_i == PY_ALU_ADD) &&
                            pycore_is_string_tag(rs1_tag) &&
                            pycore_is_string_tag(rs2_tag);
        string_path_trap = 1'b0;
        string_path_trap_code = PY_TRAP_NONE;
        string_result_entry = pycore_make_entry(PY_TAG_OBJECT, '0);
        string_store_fire = 1'b0;
        string_heap_alloc_d = string_heap_alloc_r;
        string_short_payload = '0;
        string_lhs_len = 0;
        string_rhs_len = 0;
        string_concat_len = 0;
        string_lhs_addr = 0;
        string_rhs_addr = 0;
        string_dst_addr = 0;
        byte_value = 8'h00;
        lhs_addr_plus_len = 64'b0;
        rhs_addr_plus_len = 64'b0;
        dst_addr_plus_len = 64'b0;
        concat_len_u64 = 64'b0;
        lhs_len_u64 = 64'b0;
        rhs_len_u64 = 64'b0;

        if (string_path_valid) begin
            string_lhs_len = (rs1_tag == PY_TAG_SHORT_STR) ?
                             pycore_short_str_size(rs1_value_wide) :
                             pycore_long_str_size(rs1_value_wide);
            string_rhs_len = (rs2_tag == PY_TAG_SHORT_STR) ?
                             pycore_short_str_size(rs2_value_wide) :
                             pycore_long_str_size(rs2_value_wide);
            string_lhs_addr = (rs1_tag == PY_TAG_LONG_STR) ? pycore_long_str_addr(rs1_value_wide) : 0;
            string_rhs_addr = (rs2_tag == PY_TAG_LONG_STR) ? pycore_long_str_addr(rs2_value_wide) : 0;

            lhs_len_u64 = string_lhs_len[63:0];
            rhs_len_u64 = string_rhs_len[63:0];
            lhs_addr_plus_len = string_lhs_addr[63:0] + lhs_len_u64;
            rhs_addr_plus_len = string_rhs_addr[63:0] + rhs_len_u64;

            if ((rs1_tag == PY_TAG_SHORT_STR) && (string_lhs_len > PYCORE_SHORT_STR_MAX_BYTES)) begin
                string_path_trap = 1'b1;
                string_path_trap_code = PY_TRAP_TYPE;
            end else if ((rs2_tag == PY_TAG_SHORT_STR) && (string_rhs_len > PYCORE_SHORT_STR_MAX_BYTES)) begin
                string_path_trap = 1'b1;
                string_path_trap_code = PY_TRAP_TYPE;
            end else if ((rs1_tag == PY_TAG_LONG_STR) &&
                         ((lhs_addr_plus_len < string_lhs_addr[63:0]) ||
                          (lhs_addr_plus_len > STRING_MEM_BYTES_U64))) begin
                string_path_trap = 1'b1;
                string_path_trap_code = PY_TRAP_MEM_FAULT;
            end else if ((rs2_tag == PY_TAG_LONG_STR) &&
                         ((rhs_addr_plus_len < string_rhs_addr[63:0]) ||
                          (rhs_addr_plus_len > STRING_MEM_BYTES_U64))) begin
                string_path_trap = 1'b1;
                string_path_trap_code = PY_TRAP_MEM_FAULT;
            end else begin
                string_concat_len = string_lhs_len + string_rhs_len;
                concat_len_u64 = string_concat_len[63:0];
                if ((concat_len_u64 < lhs_len_u64) || (concat_len_u64 > STRING_MAX_LEN_U64)) begin
                    string_path_trap = 1'b1;
                    string_path_trap_code = PY_TRAP_MEM_FAULT;
                end else if (concat_len_u64 <= PYCORE_SHORT_STR_MAX_BYTES) begin
                    for (i = 0; i < PYCORE_SHORT_STR_MAX_BYTES; i++) begin
                        if (i < string_concat_len) begin
                            if (i < string_lhs_len) begin
                                byte_value = string_operand_byte(rs1_tag, rs1_value_wide, i);
                            end else begin
                                byte_value = string_operand_byte(
                                    rs2_tag,
                                    rs2_value_wide,
                                    i - string_lhs_len
                                );
                            end
                            string_short_payload[119-(i*8)-:8] = byte_value;
                        end
                    end
                    string_result_entry = pycore_make_short_str_entry(
                        string_concat_len[3:0],
                        string_short_payload
                    );
                end else begin
                    string_dst_addr = (string_heap_alloc_r < STRING_RUNTIME_BASE_U64) ?
                                      STRING_RUNTIME_BASE_U64 : string_heap_alloc_r;
                    dst_addr_plus_len = string_dst_addr[63:0] + concat_len_u64;
                    if ((dst_addr_plus_len < string_dst_addr[63:0]) ||
                        (dst_addr_plus_len > STRING_MEM_BYTES_U64)) begin
                        string_path_trap = 1'b1;
                        string_path_trap_code = PY_TRAP_MEM_FAULT;
                    end else begin
                        string_store_fire = 1'b1;
                        string_heap_alloc_d = dst_addr_plus_len;
                        string_result_entry = pycore_make_long_str_entry(
                            concat_len_u64,
                            string_dst_addr[63:0]
                        );
                    end
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            string_heap_alloc_r <= STRING_RUNTIME_BASE_U64;
        end else if (valid_i && string_path_valid && !string_path_trap && string_store_fire) begin
            int i;
            logic [7:0] byte_value;
            logic [63:0] rhs_idx;
            int unsigned dst_idx;
            int unsigned src_idx;

            for (i = 0; i < STRING_MAX_LEN; i++) begin
                if (i < string_concat_len) begin
                    if (i < string_lhs_len) begin
                        if (rs1_tag == PY_TAG_SHORT_STR) begin
                            byte_value = pycore_short_str_byte(rs1_value_wide, i[3:0]);
                        end else begin
                            src_idx = int'(string_lhs_addr[63:0] + i[63:0]);
                            byte_value = string_mem[src_idx];
                        end
                    end else begin
                        rhs_idx = i[63:0] - string_lhs_len[63:0];
                        if (rs2_tag == PY_TAG_SHORT_STR) begin
                            byte_value = pycore_short_str_byte(rs2_value_wide, rhs_idx[3:0]);
                        end else begin
                            src_idx = int'(string_rhs_addr[63:0] + rhs_idx);
                            byte_value = string_mem[src_idx];
                        end
                    end
                    dst_idx = int'(string_dst_addr[63:0] + i[63:0]);
                    string_mem[dst_idx] = byte_value;
                end
            end
            string_heap_alloc_r <= string_heap_alloc_d;
        end
    end

    always_comb begin
        logic [63:0] selected_value;
        logic [PYCORE_VAL_WIDTH-1:0] wide_value;

        selected_value = 64'b0;
        stall_o = mul_stall || div_stall || fpu_stall;
        trap_o = valid_i && tag_trap;
        trap_code_o = tag_trap_code;
        result_o = pycore_make_entry(PY_TAG_OBJECT, '0);

        if (string_path_valid) begin
            stall_o = 1'b0;
            trap_o = valid_i && string_path_trap;
            trap_code_o = string_path_trap_code;
            result_o = string_result_entry;
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
                default: begin
                    trap_o = valid_i;
                    trap_code_o = PY_TRAP_TYPE;
                end
            endcase

            if (result_tag == PY_TAG_INT) begin
                wide_value = {{64{selected_value[63]}}, selected_value};
            end else begin
                wide_value = {64'b0, selected_value};
            end
            result_o = pycore_make_entry(result_tag, wide_value);
        end
    end

endmodule
