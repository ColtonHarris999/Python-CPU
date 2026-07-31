`include "pycore_defs.svh"

module tb_type_pairs;
    logic clk;
    logic rst_n;
    logic valid;
    logic [4:0] alu_op;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs1;
    logic [PYCORE_ENTRY_WIDTH-1:0] rs2;
    logic [PYCORE_ENTRY_WIDTH-1:0] result;
    logic stall;
    logic trap;
    logic [4:0] trap_code;
    int tests_run;

    pycore_exec dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .valid_i(valid),
        .alu_op_i(alu_op),
        .rs1_i(rs1),
        .rs2_i(rs2),
        .string_path_valid_i(1'b0),
        .string_result_i('0),
        .string_trap_i(1'b0),
        .string_trap_code_i(PY_TRAP_NONE),
        .result_o(result),
        .stall_o(stall),
        .trap_o(trap),
        .trap_code_o(trap_code)
    );

    always #5 clk = ~clk;

    task automatic check(input bit condition, input string message);
        begin
            if (!condition) begin
                $error("%s", message);
                $finish;
            end
        end
    endtask

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] entry(
        input logic [3:0] tag, input logic [63:0] value
    );
        begin
            entry = pycore_make_entry(tag, {64'b0, value});
        end
    endfunction

    function automatic logic [3:0] tag_by_index(input int idx);
        begin
            unique case (idx)
                0: tag_by_index = PY_TAG_UNINIT;
                1: tag_by_index = PY_TAG_INT;
                2: tag_by_index = PY_TAG_FLOAT;
                3: tag_by_index = PY_TAG_COMPLEX;
                4: tag_by_index = PY_TAG_BOOL;
                5: tag_by_index = PY_TAG_ITER;
                6: tag_by_index = PY_TAG_OBJECT;
                default: tag_by_index = PY_TAG_OBJECT;
            endcase
        end
    endfunction

    function automatic string tag_name(input logic [3:0] tag);
        begin
            unique case (tag)
                PY_TAG_UNINIT: tag_name = "UNINITIALIZED";
                PY_TAG_INT: tag_name = "INT";
                PY_TAG_FLOAT: tag_name = "FLOAT";
                PY_TAG_COMPLEX: tag_name = "COMPLEX";
                PY_TAG_BOOL: tag_name = "BOOL";
                PY_TAG_ITER: tag_name = "ITER";
                PY_TAG_OBJECT: tag_name = "OBJECT";
                default: tag_name = "RESERVED";
            endcase
        end
    endfunction

    function automatic string op_name(input logic [4:0] op);
        begin
            unique case (op)
                PY_ALU_ADD: op_name = "ADD";
                PY_ALU_MUL: op_name = "MUL";
                default: op_name = "UNKNOWN";
            endcase
        end
    endfunction

    function automatic logic is_numeric(input logic [3:0] tag);
        begin
            is_numeric = (tag == PY_TAG_INT) || (tag == PY_TAG_FLOAT) ||
                         (tag == PY_TAG_COMPLEX) || (tag == PY_TAG_BOOL);
        end
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] entry_for_tag(input logic [3:0] tag);
        begin
            unique case (tag)
                PY_TAG_INT: entry_for_tag = entry(tag, 64'd2);
                PY_TAG_FLOAT: entry_for_tag = entry(tag, 64'h3ff8_0000_0000_0000); // 1.5
                PY_TAG_BOOL: entry_for_tag = entry(tag, 64'd1);
                PY_TAG_COMPLEX: entry_for_tag = pycore_make_entry(
                    PY_TAG_COMPLEX,
                    pycore_complex_value($realtobits(2.0), $realtobits(1.0))); // 2+1j
                PY_TAG_ITER: entry_for_tag = entry(tag, 64'h0000_0000_0000_1000);
                default: entry_for_tag = entry(tag, 64'd0);
            endcase
        end
    endfunction

    function automatic real real_for_tag(input logic [3:0] tag);
        begin
            unique case (tag)
                PY_TAG_INT: real_for_tag = 2.0;
                PY_TAG_FLOAT: real_for_tag = 1.5;
                PY_TAG_BOOL: real_for_tag = 1.0;
                PY_TAG_COMPLEX: real_for_tag = 2.0;
                default: real_for_tag = 0.0;
            endcase
        end
    endfunction

    function automatic real imag_for_tag(input logic [3:0] tag);
        begin
            imag_for_tag = (tag == PY_TAG_COMPLEX) ? 1.0 : 0.0;
        end
    endfunction

    function automatic longint signed int_for_tag(input logic [3:0] tag);
        begin
            unique case (tag)
                PY_TAG_INT: int_for_tag = 2;
                PY_TAG_BOOL: int_for_tag = 1;
                default: int_for_tag = 0;
            endcase
        end
    endfunction

    function automatic logic expect_trap(input logic [3:0] tag_a, input logic [3:0] tag_b);
        begin
            expect_trap = !(is_numeric(tag_a) && is_numeric(tag_b));
        end
    endfunction

    function automatic logic [3:0] expected_tag(input logic [3:0] tag_a, input logic [3:0] tag_b);
        begin
            if (tag_a == PY_TAG_COMPLEX || tag_b == PY_TAG_COMPLEX) begin
                expected_tag = PY_TAG_COMPLEX;
            end else if (tag_a == PY_TAG_FLOAT || tag_b == PY_TAG_FLOAT) begin
                expected_tag = PY_TAG_FLOAT;
            end else begin
                expected_tag = PY_TAG_INT;
            end
        end
    endfunction

    function automatic logic [PYCORE_VAL_WIDTH-1:0] expected_value(
        input logic [4:0] op,
        input logic [3:0] tag_a,
        input logic [3:0] tag_b
    );
        real a_real;
        real b_real;
        real a_imag;
        real b_imag;
        real r_real;
        real r_imag;
        longint signed a_int;
        longint signed b_int;
        longint signed result_int;
        begin
            if (expected_tag(tag_a, tag_b) == PY_TAG_COMPLEX) begin
                a_real = real_for_tag(tag_a);
                b_real = real_for_tag(tag_b);
                a_imag = imag_for_tag(tag_a);
                b_imag = imag_for_tag(tag_b);
                if (op == PY_ALU_ADD) begin
                    r_real = a_real + b_real;
                    r_imag = a_imag + b_imag;
                end else begin
                    r_real = (a_real * b_real) - (a_imag * b_imag);
                    r_imag = (a_real * b_imag) + (a_imag * b_real);
                end
                expected_value = pycore_complex_value($realtobits(r_real), $realtobits(r_imag));
            end else if (expected_tag(tag_a, tag_b) == PY_TAG_FLOAT) begin
                a_real = real_for_tag(tag_a);
                b_real = real_for_tag(tag_b);
                expected_value = {64'b0,
                    $realtobits(op == PY_ALU_ADD ? (a_real + b_real) : (a_real * b_real))};
            end else begin
                a_int = int_for_tag(tag_a);
                b_int = int_for_tag(tag_b);
                result_int = op == PY_ALU_ADD ? (a_int + b_int) : (a_int * b_int);
                expected_value = {{64{result_int[63]}}, result_int[63:0]};
            end
        end
    endfunction

    task automatic run_pair(input logic [4:0] op, input logic [3:0] tag_a, input logic [3:0] tag_b);
        string label;
        begin
            label = $sformatf("%s %s x %s", op_name(op), tag_name(tag_a), tag_name(tag_b));
            alu_op = op;
            rs1 = entry_for_tag(tag_a);
            rs2 = entry_for_tag(tag_b);
            #1;
            tests_run++;

            if (expect_trap(tag_a, tag_b)) begin
                check(trap, {label, " should trap"});
                check(trap_code == PY_TRAP_TYPE, {label, " should raise TYPE_TRAP"});
            end else begin
                check(!trap, {label, " should not trap"});
                check(pycore_get_tag(result) == expected_tag(tag_a, tag_b), {label, " result tag mismatch"});
                check(pycore_get_val(result) == expected_value(op, tag_a, tag_b),
                      {label, " result value mismatch"});
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        alu_op = PY_ALU_ADD;
        rs1 = '0;
        rs2 = '0;
        tests_run = 0;
        #12;
        rst_n = 1'b1;
        valid = 1'b1;

        for (int op_idx = 0; op_idx < 2; op_idx++) begin
            for (int lhs_idx = 0; lhs_idx < 7; lhs_idx++) begin
                for (int rhs_idx = 0; rhs_idx < 7; rhs_idx++) begin
                    run_pair(op_idx == 0 ? PY_ALU_ADD : PY_ALU_MUL,
                             tag_by_index(lhs_idx),
                             tag_by_index(rhs_idx));
                end
            end
        end

        check(tests_run == 98, "type-pair matrix should run 98 cases");
        $display("PASS: add/multiply type-pair matrix complete (%0d cases)", tests_run);
        $finish;
    end
endmodule
