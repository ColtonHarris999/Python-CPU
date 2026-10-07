`include "pycore_defs.svh"

// Randomised + directed verification of the execute fabric's arithmetic
// units (pycore/docs/alu.md) through pycore_exec, against a CPython
// reference model (pycore/tb/alu_ref.c, DPI-C).
//
// The driver follows the core's protocol: valid_i is held with stable
// operands until stall_o drops (or trap_o rises) and sampled on the
// falling clock edge; the result is consumed in that cycle. A second
// pass issues operations back to back (valid_i held high, new operands
// presented in the cycle after each completion) so that unit re-arming
// is also exercised. Latencies are recorded per operation class and
// printed at the end; the table in alu.md is derived from them.
//
// Plusargs: +seed=<n>  +iters=<n per class>
module tb_alu_units;
    import "DPI-C" function int alu_ref(
        input int op, input int tag_a, input longint a_lo, input longint a_hi,
        input int tag_b, input longint b_lo, input longint b_hi,
        output int res_tag, output longint r_lo, output longint r_hi);
    import "DPI-C" function real alu_ref_pow_ulps(
        input longint a_bits, input longint b_bits, input longint hw_bits);
    import "DPI-C" function longint alu_ref_fmod(input longint a, input longint b);
    import "DPI-C" function longint alu_ref_floor(input longint a);
    import "DPI-C" function longint alu_ref_i64_to_f64(input longint a);

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

    int seed;
    int iters;
    int errors;
    int checks;
    bit back_to_back;

    // ---- latency bookkeeping ------------------------------------------
    localparam int NCLASS = 96;
    string  cls_name [NCLASS];
    int     cls_min  [NCLASS];
    int     cls_max  [NCLASS];
    longint cls_sum  [NCLASS];
    int     cls_n    [NCLASS];
    int     ncls;

    function automatic int cls_index(input string name);
        for (int i = 0; i < ncls; i++) if (cls_name[i] == name) return i;
        if (ncls == NCLASS) begin
            $display("too many latency classes");
            $fatal(1);
        end
        cls_name[ncls] = name;
        cls_min[ncls] = 1 << 30;
        cls_max[ncls] = 0;
        cls_sum[ncls] = 0;
        cls_n[ncls] = 0;
        ncls++;
        return ncls - 1;
    endfunction

    // The simulator stops on $error; count mismatches instead so one run
    // reports all of them (the first 50 are printed).
    task automatic fail(input string msg);
        errors++;
        if (errors <= 50) $display("ERROR: %s", msg);
    endtask

    task automatic record_latency(input string name, input int cycles);
        int i = cls_index(name);
        if (cycles < cls_min[i]) cls_min[i] = cycles;
        if (cycles > cls_max[i]) cls_max[i] = cycles;
        cls_sum[i] += cycles;
        cls_n[i]++;
    endtask

    function automatic string op_name(input logic [4:0] op);
        unique case (op)
            PY_ALU_ADD: return "ADD";       PY_ALU_SUB: return "SUB";
            PY_ALU_MUL: return "MUL";       PY_ALU_FLOOR_DIV: return "FLOOR_DIV";
            PY_ALU_TRUE_DIV: return "TRUE_DIV"; PY_ALU_MOD: return "MOD";
            PY_ALU_POWER: return "POWER";   PY_ALU_LSHIFT: return "LSHIFT";
            PY_ALU_RSHIFT: return "RSHIFT"; PY_ALU_AND: return "AND";
            PY_ALU_OR: return "OR";         PY_ALU_XOR: return "XOR";
            PY_ALU_NEG: return "NEG";       PY_ALU_POS: return "POS";
            PY_ALU_INVERT: return "INVERT"; PY_ALU_NOT: return "NOT";
            PY_ALU_EQ: return "EQ";         PY_ALU_NE: return "NE";
            PY_ALU_LT: return "LT";         PY_ALU_LE: return "LE";
            PY_ALU_GT: return "GT";         PY_ALU_GE: return "GE";
            PY_ALU_PASS: return "PASS";
            default: return "?";
        endcase
    endfunction

    function automatic string tag_name(input logic [3:0] tag);
        unique case (tag)
            PY_TAG_INT: return "INT";
            PY_TAG_FLOAT: return "FLOAT";
            PY_TAG_COMPLEX: return "COMPLEX";
            PY_TAG_BOOL: return "BOOL";
            default: return $sformatf("TAG%0d", tag);
        endcase
    endfunction

    function automatic bit is_nan64(input logic [63:0] v);
        return (v[62:52] == 11'h7FF) && (v[51:0] != 52'd0);
    endfunction

    // ---- driver ---------------------------------------------------------
    // Presents one operation and waits for completion. Returns the
    // sampled outputs and the number of cycles valid_i was held.
    task automatic issue(
        input  logic [4:0] op,
        input  logic [PYCORE_ENTRY_WIDTH-1:0] a,
        input  logic [PYCORE_ENTRY_WIDTH-1:0] b,
        output logic [PYCORE_ENTRY_WIDTH-1:0] res,
        output logic got_trap,
        output logic [4:0] got_code,
        output int cycles
    );
        cycles = 0;
        alu_op = op;
        rs1 = a;
        rs2 = b;
        valid = 1'b1;
        forever begin
            @(negedge clk);
            cycles++;
            if (trap && stall) begin
                fail($sformatf("trap asserted together with stall (%s)", op_name(op)));
            end
            if (!stall || trap) break;
            if (cycles > 2000) begin
                fail($sformatf("timeout waiting for %s", op_name(op)));
                break;
            end
        end
        res      = result;
        got_trap = trap;
        got_code = trap_code;
        // Consume the result on this edge; the core moves on to S_MEM.
        @(posedge clk);
        #1;
        if (!back_to_back) begin
            valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // ---- checker ---------------------------------------------------------
    task automatic run_case(
        input logic [4:0] op,
        input logic [3:0] tag_a, input logic [127:0] va,
        input logic [3:0] tag_b, input logic [127:0] vb,
        input string cls
    );
        logic [PYCORE_ENTRY_WIDTH-1:0] res;
        logic got_trap;
        logic [4:0] got_code;
        int cycles;
        int ref_trap;
        int ref_tag;
        longint r_lo, r_hi;
        logic [127:0] rv;
        logic [3:0] rt;
        bit ok;
        bit value_ok;
        string lab;

        issue(op, pycore_make_entry(tag_a, va), pycore_make_entry(tag_b, vb),
              res, got_trap, got_code, cycles);
        checks++;
        ref_trap = alu_ref(int'(op), int'(tag_a), longint'(va[63:0]), longint'(va[127:64]),
                           int'(tag_b), longint'(vb[63:0]), longint'(vb[127:64]),
                           ref_tag, r_lo, r_hi);
        rt = pycore_get_tag(res);
        rv = pycore_get_val(res);
        lab = $sformatf("%s %s(%h,%h) %s(%h,%h)", op_name(op),
                        tag_name(tag_a), va[127:64], va[63:0],
                        tag_name(tag_b), vb[127:64], vb[63:0]);

        if (ref_trap != 0) begin
            ok = got_trap && (int'(got_code) == ref_trap);
            if (!ok) begin
                fail($sformatf("%s: expected trap %0d, got trap=%0d code=%0d res=%h",
                       lab, ref_trap, got_trap, got_code, res));
            end
            return;
        end

        if (got_trap) begin
            fail($sformatf("%s: unexpected trap code=%0d (ref tag %0d value %h%h)",
                   lab, got_code, ref_tag, r_hi, r_lo));
            return;
        end

        value_ok = 1'b1;
        if (rt != 4'(ref_tag)) begin
            value_ok = 1'b0;
        end else if (ref_tag == int'(PY_TAG_FLOAT)) begin
            value_ok = (rv[127:64] == 64'd0) &&
                       ((rv[63:0] == r_lo) || (is_nan64(rv[63:0]) && is_nan64(r_lo)));
        end else if (ref_tag == int'(PY_TAG_COMPLEX)) begin
            value_ok = ((rv[63:0] == r_lo) || (is_nan64(rv[63:0]) && is_nan64(r_lo))) &&
                       ((rv[127:64] == r_hi) || (is_nan64(rv[127:64]) && is_nan64(r_hi)));
        end else begin
            value_ok = (rv == {r_hi, r_lo});
        end
        if (!value_ok) begin
            fail($sformatf("%s: got %s %h_%h, expected %s %h_%h (%0d cycles)",
                   lab, tag_name(rt), rv[127:64], rv[63:0],
                   tag_name(4'(ref_tag)), r_hi, r_lo, cycles));
        end

        // float ** float may differ from libm only by the accumulated
        // rounding of the square-and-multiply chain; bound it for the
        // modest exponents the random generator produces.
        if (op == PY_ALU_POWER && ref_tag == int'(PY_TAG_FLOAT) && value_ok) begin
            longint bb;
            real ulps;
            bb = (tag_b == PY_TAG_FLOAT) ? longint'(vb[63:0]) :
                 ((tag_b == PY_TAG_BOOL) ? alu_ref_i64_to_f64(longint'(vb[0])) :
                                           alu_ref_i64_to_f64(longint'(vb[63:0])));
            ulps = alu_ref_pow_ulps(
                (tag_a == PY_TAG_FLOAT) ? longint'(va[63:0]) :
                ((tag_a == PY_TAG_BOOL) ? alu_ref_i64_to_f64(longint'(va[0])) :
                                          alu_ref_i64_to_f64(longint'(va[63:0]))),
                bb, longint'(rv[63:0]));
            if (ulps > 1.0) begin
                fail($sformatf("%s: pow result %h is %f x tolerance from libm", lab, rv[63:0], ulps));
            end
        end

        if (cls != "") record_latency(cls, cycles);
    endtask

    // ---- operand generators -----------------------------------------------
    function automatic logic [63:0] rand64();
        return {$urandom(), $urandom()};
    endfunction

    function automatic logic [63:0] rand_int();
        int k = $urandom_range(0, 9);
        logic [63:0] v = rand64();
        unique case (k)
            0: return 64'd0;
            1: return {{59{1'b0}}, $urandom_range(0, 31)} - 64'd16;        // small
            2: return 64'h8000_0000_0000_0000;                               // INT64_MIN
            3: return 64'h7FFF_FFFF_FFFF_FFFF;                               // INT64_MAX
            4: return 64'd1 << $urandom_range(0, 63);                         // power of two
            5: return v >> $urandom_range(0, 63);                             // random width
            6: return -(v >> $urandom_range(1, 63));                          // negative, random width
            7: return {{32{1'b0}}, $urandom()};                               // 32-bit
            default: return v;
        endcase
    endfunction

    function automatic logic [63:0] rand_f64();
        int k = $urandom_range(0, 15);
        logic sign = $urandom_range(0, 1);
        logic [51:0] frac = rand64()[51:0];
        unique case (k)
            0: return {sign, 63'd0};                                            // ±0
            1: return {sign, 11'h7FF, 52'd0};                                   // ±inf
            2: return {sign, 11'h7FF, 1'b1, frac[50:0]};                        // NaN
            3: return {sign, 11'd0, frac};                                      // subnormal
            4: return {sign, 11'd0, 51'd0, 1'b1};                               // smallest subnormal
            5: return {sign, 11'h7FE, {52{1'b1}}};                              // ±DBL_MAX
            6: return {sign, 11'd1, frac};                                      // smallest normal binade
            7, 8: begin                                                         // small integer value
                longint v = longint'($urandom_range(0, 40)) - 20;
                return alu_ref_i64_to_f64(v);
            end
            9: begin                                                            // n + 0.5
                logic [63:0] odd = alu_ref_i64_to_f64(2 * (longint'($urandom_range(0, 40)) - 20) + 1);
                return {odd[63], odd[62:52] - 11'd1, odd[51:0]};                // (2n+1)/2
            end
            10, 11: return {sign, 11'd1023 + 11'($urandom_range(0, 40)) - 11'd20, frac}; // near 1
            default: return {sign, 11'($urandom_range(1, 2045)), frac};        // any normal
        endcase
    endfunction

    // Exponents for float **: mostly small integers so libm agreement can
    // be bounded, with a sprinkling of fractions / specials.
    function automatic logic [63:0] rand_pow_exp();
        int k = $urandom_range(0, 9);
        if (k < 7) return alu_ref_i64_to_f64(longint'($urandom_range(0, 40)) - 20);
        if (k == 7) return 64'h3FE0_0000_0000_0000;      // 0.5 -> hardware exception
        return rand_f64();
    endfunction

    // ---- test programs ----------------------------------------------------
    task automatic int_pairs(input int n);
        logic [4:0] ops [16] = '{PY_ALU_ADD, PY_ALU_SUB, PY_ALU_MUL, PY_ALU_FLOOR_DIV,
                                 PY_ALU_TRUE_DIV, PY_ALU_MOD, PY_ALU_POWER, PY_ALU_LSHIFT,
                                 PY_ALU_RSHIFT, PY_ALU_AND, PY_ALU_OR, PY_ALU_XOR,
                                 PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_GE};
        for (int i = 0; i < n; i++) begin
            logic [4:0] op = ops[$urandom_range(0, 15)];
            logic [3:0] ta = ($urandom_range(0, 7) == 0) ? PY_TAG_BOOL : PY_TAG_INT;
            logic [3:0] tb = ($urandom_range(0, 7) == 0) ? PY_TAG_BOOL : PY_TAG_INT;
            logic [63:0] a = (ta == PY_TAG_BOOL) ? 64'($urandom_range(0, 1)) : rand_int();
            logic [63:0] b = (tb == PY_TAG_BOOL) ? 64'($urandom_range(0, 1)) : rand_int();
            if (op == PY_ALU_POWER && $urandom_range(0, 3) != 0)
                b = 64'($urandom_range(0, 70));
            run_case(op, ta, {64'd0, a}, tb, {64'd0, b},
                     (ta == PY_TAG_INT && tb == PY_TAG_INT) ? {"INT ", op_name(op)} : "");
        end
        for (int i = 0; i < n / 4; i++) begin
            logic [4:0] op = (i % 3 == 0) ? PY_ALU_NEG : ((i % 3 == 1) ? PY_ALU_POS : PY_ALU_INVERT);
            run_case(op, PY_TAG_INT, {64'd0, rand_int()}, PY_TAG_INT, 128'd0, {"INT ", op_name(op)});
        end
    endtask

    task automatic float_pairs(input int n);
        logic [4:0] ops [14] = '{PY_ALU_ADD, PY_ALU_SUB, PY_ALU_MUL, PY_ALU_FLOOR_DIV,
                                 PY_ALU_TRUE_DIV, PY_ALU_MOD, PY_ALU_POWER,
                                 PY_ALU_EQ, PY_ALU_NE, PY_ALU_LT, PY_ALU_LE, PY_ALU_GT,
                                 PY_ALU_GE, PY_ALU_ADD};
        for (int i = 0; i < n; i++) begin
            logic [4:0] op = ops[$urandom_range(0, 13)];
            int mix = $urandom_range(0, 9);
            logic [3:0] ta = (mix == 0) ? PY_TAG_INT : ((mix == 1) ? PY_TAG_BOOL : PY_TAG_FLOAT);
            logic [3:0] tb = (mix == 2) ? PY_TAG_INT : ((mix == 3) ? PY_TAG_BOOL : PY_TAG_FLOAT);
            logic [63:0] a, b;
            a = (ta == PY_TAG_FLOAT) ? rand_f64() :
                ((ta == PY_TAG_BOOL) ? 64'($urandom_range(0, 1)) : rand_int());
            b = (tb == PY_TAG_FLOAT) ? ((op == PY_ALU_POWER) ? rand_pow_exp() : rand_f64()) :
                ((tb == PY_TAG_BOOL) ? 64'($urandom_range(0, 1)) : rand_int());
            run_case(op, ta, {64'd0, a}, tb, {64'd0, b},
                     (ta == PY_TAG_FLOAT && tb == PY_TAG_FLOAT) ? {"FLOAT ", op_name(op)} : "");
        end
        for (int i = 0; i < n / 4; i++) begin
            logic [4:0] op = (i % 3 == 0) ? PY_ALU_NEG : ((i % 3 == 1) ? PY_ALU_POS : PY_ALU_NOT);
            run_case(op, PY_TAG_FLOAT, {64'd0, rand_f64()}, PY_TAG_INT, 128'd0, {"FLOAT ", op_name(op)});
        end
    endtask

    task automatic complex_pairs(input int n);
        logic [4:0] ops [8] = '{PY_ALU_ADD, PY_ALU_SUB, PY_ALU_MUL, PY_ALU_TRUE_DIV,
                                PY_ALU_EQ, PY_ALU_NE, PY_ALU_MUL, PY_ALU_TRUE_DIV};
        for (int i = 0; i < n; i++) begin
            logic [4:0] op = ops[$urandom_range(0, 7)];
            int mix = $urandom_range(0, 9);
            logic [3:0] ta = (mix == 0) ? PY_TAG_FLOAT : ((mix == 1) ? PY_TAG_INT : PY_TAG_COMPLEX);
            logic [3:0] tb = (mix == 2) ? PY_TAG_FLOAT : ((mix == 3) ? PY_TAG_INT : PY_TAG_COMPLEX);
            logic [127:0] a, b;
            a = (ta == PY_TAG_COMPLEX) ? {rand_f64(), rand_f64()} :
                ((ta == PY_TAG_FLOAT) ? {64'd0, rand_f64()} : {64'd0, rand_int()});
            b = (tb == PY_TAG_COMPLEX) ? {rand_f64(), rand_f64()} :
                ((tb == PY_TAG_FLOAT) ? {64'd0, rand_f64()} : {64'd0, rand_int()});
            // A few exact equalities so EQ/NE see both outcomes.
            if ((op == PY_ALU_EQ || op == PY_ALU_NE) && $urandom_range(0, 1)) b = a;
            run_case(op, ta, a, tb, b,
                     (ta == PY_TAG_COMPLEX && tb == PY_TAG_COMPLEX) ? {"COMPLEX ", op_name(op)} : "");
        end
        for (int i = 0; i < n / 4; i++) begin
            logic [4:0] op = (i % 3 == 0) ? PY_ALU_NEG : ((i % 3 == 1) ? PY_ALU_POS : PY_ALU_NOT);
            run_case(op, PY_TAG_COMPLEX, {rand_f64(), rand_f64()}, PY_TAG_INT, 128'd0,
                     {"COMPLEX ", op_name(op)});
        end
    endtask

    // Hand-picked corner cases (CPython-verified values).
    task automatic directed();
        // INT
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, 128'(-7), PY_TAG_INT, 128'd2, "");          // -4
        run_case(PY_ALU_MOD,       PY_TAG_INT, 128'(-7), PY_TAG_INT, 128'd2, "");          // 1
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, 128'd7, PY_TAG_INT, 128'(-2), "");          // -4
        run_case(PY_ALU_MOD,       PY_TAG_INT, 128'd7, PY_TAG_INT, 128'(-2), "");          // -1
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_INT, 128'(-1), "");                                                 // wraps
        run_case(PY_ALU_MOD, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'(-1), "");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, 128'd5, PY_TAG_INT, 128'd0, "");            // ZeroDivision
        run_case(PY_ALU_MOD, PY_TAG_INT, 128'd5, PY_TAG_INT, 128'd0, "");
        run_case(PY_ALU_MUL, PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFF}, PY_TAG_INT, 128'd2, "");
        run_case(PY_ALU_MUL, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, "");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'd62, "");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'd63, "");               // overflow trap
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'(-2), PY_TAG_INT, 128'd63, "");             // INT64_MIN
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'(-1), PY_TAG_INT, 128'd1001, "");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'd0, "");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd0, PY_TAG_INT, 128'd0, "");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'(-1), "");              // trap
        run_case(PY_ALU_TRUE_DIV, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd3, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd0, "");

        // FLOAT: rounding / cancellation / subnormal corners
        run_case(PY_ALU_ADD, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3CA0_0000_0000_0000}, "");   // 1 + 2^-53 -> 1
        run_case(PY_ALU_ADD, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3CA0_0000_0000_0001}, "");   // 1 + (2^-53 + ulp) -> 1 + 2^-52
        run_case(PY_ALU_SUB, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000}, "");   // +0
        run_case(PY_ALU_ADD, PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000}, "");   // -0 + -0 = -0
        run_case(PY_ALU_ADD, PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF}, "");   // overflow -> inf
        run_case(PY_ALU_MUL, PY_TAG_FLOAT, {64'd0, 64'h0010_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // DBL_MIN * 0.5 subnormal
        run_case(PY_ALU_MUL, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // tie -> even -> 0
        run_case(PY_ALU_MUL, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0003},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // tie -> even -> 2
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "");   // 1/3
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001},
                 PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000}, "");   // min subnormal / 2
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001}, "");   // 1 / min subnormal -> inf
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000}, "");   // 1 / -0 -> ZeroDivision
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h401E_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "");   // 7.5 % -3 = -1.5
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'hC01E_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "");   // -7.5 % 3 = 1.5
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h4018_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "");   // 6 % -3 = -0.0
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001}, "");   // DBL_MAX % min subnormal
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "");   // DBL_MAX % 3
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h7FF0_0000_0000_0000}, "");   // 1 % inf = 1
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'hBFF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h7FF0_0000_0000_0000}, "");   // -1 % inf = inf
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h401E_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "");   // 7.5 // -3 = -3
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3CA0_0000_0000_0000}, "");   // 1 // 2^-53
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "");   // -0.0 // 3 = -0.0
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h7FF0_0000_0000_0000}, "");   // 1 // inf = 0.0
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'hBFF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h7FF0_0000_0000_0000}, "");   // -1 // inf = -1.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4059_0000_0000_0000}, "");   // 2 ** 100
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC059_0000_0000_0000}, "");   // 2 ** -100
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4090_0000_0000_0000}, "");   // 2 ** 1024 -> Overflow
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC090_C000_0000_0000}, "");   // 2 ** -1072 (subnormal)
        run_case(PY_ALU_POWER, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC031_0000_0000_0000}, "");   // (-2**63) ** -17
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4024_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC074_0000_0000_0000}, "");   // 10 ** -320 (subnormal)
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4024_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC079_0000_0000_0000}, "");   // 10 ** -400 = 0.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hC000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "");   // (-2) ** 3 = -8
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hBFF0_0000_0000_0000}, "");   // 0 ** -1 -> ZeroDivision
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 2 ** 0.5 -> not supported
        run_case(PY_ALU_LT, PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0000}, "");   // -0 < +0 false
        run_case(PY_ALU_EQ, PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0000}, "");   // -0 == +0 true

        // COMPLEX
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "");  // (1+2j)/(3+4j)
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h3FF0_0000_0000_0000}, "");  // |bi| > |br|
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'd0, 64'd0}, "");                                   // ZeroDivision
        run_case(PY_ALU_MUL, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "");
    endtask

    // Canonical operand pairs whose latencies are quoted in alu.md.
    task automatic latency_probes();
        run_case(PY_ALU_MUL, PY_TAG_INT, 128'd12345, PY_TAG_INT, 128'(-678), "probe INT MUL");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'd7, "probe INT // |a|<|b|");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, 128'(-7), PY_TAG_INT, 128'd2, "probe INT // 3-bit/2-bit");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFF}, PY_TAG_INT,
                 128'd3, "probe INT // 63-bit/2-bit");
        run_case(PY_ALU_MOD, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT,
                 128'd1, "probe INT % 64-bit/1-bit");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd7, PY_TAG_INT, 128'd1, "probe INT 7**1");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'd62, "probe INT 2**62");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'd39, "probe INT 3**39");
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'(-1), PY_TAG_INT, 128'd1001, "probe INT (-1)**1001");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd3, "probe INT 1/3");
        run_case(PY_ALU_ADD, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 1.0+3.0");
        run_case(PY_ALU_MUL, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 1.0*3.0");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 1.0/3.0");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h7FF0_0000_0000_0000}, "probe FLOAT 1.0/inf");
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h401E_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "probe FLOAT 7.5%-3.0");
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h4018_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 6.0%3.0");
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 1.0%3.0");
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h4330_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 2**52%3.0");
        run_case(PY_ALU_MOD, PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001}, "probe FLOAT DBL_MAX%min");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h401E_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "probe FLOAT 7.5//-3.0");
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_FLOAT, {64'd0, 64'h4018_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 6.0//3.0");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000}, "probe FLOAT 2.0**2");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4059_0000_0000_0000}, "probe FLOAT 2.0**100");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC059_0000_0000_0000}, "probe FLOAT 2.0**-100");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC090_C000_0000_0000}, "probe FLOAT 2.0**-1072");
        run_case(PY_ALU_ADD, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX +");
        run_case(PY_ALU_MUL, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX *");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX /");
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        alu_op = PY_ALU_ADD;
        rs1 = '0;
        rs2 = '0;
        errors = 0;
        checks = 0;
        ncls = 0;
        back_to_back = 1'b0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("iters=%d", iters)) iters = 3000;
        void'($urandom(seed));
        #12;
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        latency_probes();
        directed();
        int_pairs(iters);
        float_pairs(iters);
        complex_pairs(iters / 2);

        back_to_back = 1'b1;
        directed();
        int_pairs(iters / 2);
        float_pairs(iters / 2);
        complex_pairs(iters / 4);
        valid = 1'b0;
        @(posedge clk);

        $display("");
        $display("Latency (cycles valid_i held, incl. the completion cycle)");
        $display("%-20s %6s %6s %8s %6s", "class", "min", "max", "mean", "n");
        for (int i = 0; i < ncls; i++) begin
            $display("%-20s %6d %6d %8.1f %6d", cls_name[i], cls_min[i], cls_max[i],
                     real'(cls_sum[i]) / real'(cls_n[i]), cls_n[i]);
        end
        $display("");
        if (errors != 0) begin
            $display("FAIL: %0d of %0d ALU checks failed (seed %0d)", errors, checks, seed);
            $fatal(1);
        end
        $display("PASS: %0d ALU unit checks against the CPython reference (seed %0d)", checks, seed);
        $finish;
    end
endmodule
