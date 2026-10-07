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
    import "DPI-C" function int alu_ref_pow_exact(
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
    int pow_checked, pow_exact;   // float ** float results compared with libm
    int trap_count [32];          // expected (and matched) traps per code
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

    function automatic string trap_name(input logic [4:0] code);
        unique case (code)
            PY_TRAP_TYPE:          return "TYPE";
            PY_TRAP_DIV_ZERO:      return "DIV_ZERO";
            PY_TRAP_FPU_EXCEPTION: return "FPU_EXCEPTION";
            PY_TRAP_OVERFLOW:      return "OVERFLOW";
            PY_TRAP_VALUE:         return "VALUE";
            default:               return "?";
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
            if (ok) trap_count[ref_trap]++;
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

        // float ** float: the reference model is bit-exact for the
        // hardware algorithm; additionally bound the distance to libm
        // pow() (1 ulp, 2 for x ** -2) and count exact agreement.
        if (op == PY_ALU_POWER && ref_tag == int'(PY_TAG_FLOAT) && value_ok) begin
            longint aa, bb;
            real ulps;
            aa = (tag_a == PY_TAG_FLOAT) ? longint'(va[63:0]) :
                 ((tag_a == PY_TAG_BOOL) ? alu_ref_i64_to_f64(longint'(va[0])) :
                                           alu_ref_i64_to_f64(longint'(va[63:0])));
            bb = (tag_b == PY_TAG_FLOAT) ? longint'(vb[63:0]) :
                 ((tag_b == PY_TAG_BOOL) ? alu_ref_i64_to_f64(longint'(vb[0])) :
                                           alu_ref_i64_to_f64(longint'(vb[63:0])));
            ulps = alu_ref_pow_ulps(aa, bb, longint'(rv[63:0]));
            if (ulps > 1.0) begin
                fail($sformatf("%s: pow result %h is %f x tolerance from libm", lab, rv[63:0], ulps));
            end
            pow_checked++;
            if (alu_ref_pow_exact(aa, bb, longint'(rv[63:0]))) pow_exact++;
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

    // Exponents for float **: small integers (both the square-and-multiply
    // and the log / exp path), fractions of modest size, and specials.
    function automatic logic [63:0] rand_pow_exp();
        int k = $urandom_range(0, 11);
        logic [63:0] v;
        if (k < 4) return alu_ref_i64_to_f64(longint'($urandom_range(0, 40)) - 20);
        if (k == 4) return 64'h3FE0_0000_0000_0000;                                 // 0.5
        if (k == 5) begin                                                           // n / 16
            v = alu_ref_i64_to_f64(longint'($urandom_range(0, 1600)) - 800);
            return (v == 64'd0) ? v : {v[63], v[62:52] - 11'd4, v[51:0]};
        end
        if (k == 6) return {1'($urandom_range(0, 1)), 11'd1023 + 11'($urandom_range(0, 10)) - 11'd6, rand64()[51:0]}; // |y| in [2^-6, 2^5)
        if (k == 7) return {1'($urandom_range(0, 1)), 11'd1023 + 11'($urandom_range(0, 50)) - 11'd30, rand64()[51:0]}; // wide range
        if (k == 8) return alu_ref_i64_to_f64(longint'($urandom_range(0, 3000)) - 1500);  // larger integer
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
            logic [4:0] op = (i % 4 == 0) ? PY_ALU_NEG : ((i % 4 == 1) ? PY_ALU_POS :
                             ((i % 4 == 2) ? PY_ALU_INVERT : PY_ALU_NOT));
            run_case(op, PY_TAG_INT, {64'd0, rand_int()}, PY_TAG_INT, 128'd0, {"INT ", op_name(op)});
        end
    endtask

    // Dedicated float ** float stress: finite positive / negative bases
    // of every magnitude against the exponent mix above.
    task automatic pow_pairs(input int n);
        for (int i = 0; i < n; i++) begin
            logic [63:0] a = rand_f64();
            logic [63:0] b = rand_pow_exp();
            if ($urandom_range(0, 2) != 0) begin
                // mostly finite non-zero bases around 1 or anywhere normal
                int k = $urandom_range(0, 3);
                a = (k == 0) ? {1'($urandom_range(0, 1)), 11'd1023, rand64()[51:0]} :
                    (k == 1) ? {1'b0, 11'd1023 + 11'($urandom_range(0, 6)) - 11'd3, rand64()[51:0]} :
                    (k == 2) ? {1'b0, 11'($urandom_range(1, 2045)), rand64()[51:0]} :
                               {1'b0, 11'd1023, 44'd0, rand64()[7:0]};        // 1 + tiny
            end
            run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, a}, PY_TAG_FLOAT, {64'd0, b}, "FLOAT POWER");
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
        run_case(PY_ALU_TRUE_DIV, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd3, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd0, "");

        // INT overflow traps (CPython promotes to a big int) and ValueErrors
        run_case(PY_ALU_ADD, PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFF}, PY_TAG_INT, 128'd1, "");
        run_case(PY_ALU_ADD, PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFF}, PY_TAG_BOOL, 128'd1, "");
        run_case(PY_ALU_ADD, PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFE}, PY_TAG_INT, 128'd1, "");   // fits
        run_case(PY_ALU_SUB, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'd1, "");
        run_case(PY_ALU_SUB, PY_TAG_INT, 128'd0, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, "");
        run_case(PY_ALU_SUB, PY_TAG_INT, 128'(-1), PY_TAG_INT, {64'd0, 64'h7FFF_FFFF_FFFF_FFFF}, ""); // fits
        run_case(PY_ALU_MUL, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'(-1), "");
        run_case(PY_ALU_MUL, PY_TAG_INT, {64'd0, 64'h4000_0000_0000_0000}, PY_TAG_INT, 128'd2, "");  // 2^63
        run_case(PY_ALU_MUL, PY_TAG_INT, {64'd0, 64'h4000_0000_0000_0000}, PY_TAG_INT, 128'(-2), ""); // INT64_MIN fits
        run_case(PY_ALU_MUL, PY_TAG_INT, 128'(-3), PY_TAG_INT, {64'd0, 64'h2AAA_AAAA_AAAA_AAAB}, ""); // -2^63-1
        run_case(PY_ALU_MUL, PY_TAG_INT, 128'(-1), PY_TAG_INT, 128'(-1), "");                         // 1
        run_case(PY_ALU_NEG, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'd0, "");
        run_case(PY_ALU_NEG, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0001}, PY_TAG_INT, 128'd0, "");   // fits
        run_case(PY_ALU_INVERT, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'd0, ""); // INT64_MAX
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd62, "");                         // fits
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd63, "");                         // 2^63 overflow
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'(-1), PY_TAG_INT, 128'd63, "");                       // INT64_MIN fits
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'(-2), PY_TAG_INT, 128'd63, "");                       // overflow
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'd62, "");                         // overflow
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'd64, "");                         // overflow
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd0, PY_TAG_INT, 128'd1000, "");                       // 0
        run_case(PY_ALU_LSHIFT, PY_TAG_INT, 128'd5, PY_TAG_INT, 128'(-1), "");                        // ValueError
        run_case(PY_ALU_RSHIFT, PY_TAG_INT, 128'd5, PY_TAG_INT, 128'(-1), "");                        // ValueError
        run_case(PY_ALU_RSHIFT, PY_TAG_INT, 128'(-5), PY_TAG_INT, 128'd1000, "");                     // -1
        run_case(PY_ALU_RSHIFT, PY_TAG_INT, 128'd5, PY_TAG_INT, 128'd1000, "");                       // 0
        run_case(PY_ALU_LSHIFT, PY_TAG_BOOL, 128'd1, PY_TAG_INT, 128'd2, "");                         // True << 2 = 4
        run_case(PY_ALU_RSHIFT, PY_TAG_INT, 128'd8, PY_TAG_BOOL, 128'd1, "");                         // 8 >> True = 4
        run_case(PY_ALU_LSHIFT, PY_TAG_BOOL, 128'd1, PY_TAG_BOOL, 128'd1, "");                        // 2
        run_case(PY_ALU_FLOOR_DIV, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'd1, ""); // fits
        run_case(PY_ALU_NOT, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'd0, "");                             // False
        run_case(PY_ALU_NOT, PY_TAG_INT, 128'd0, PY_TAG_INT, 128'd0, "");                             // True
        run_case(PY_ALU_NOT, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'd0, "");  // False
        run_case(PY_ALU_NOT, PY_TAG_BOOL, 128'd1, PY_TAG_INT, 128'd0, "");

        // INT ** negative INT is a float
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'(-1), "");              // 1/3
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'(-1), "");              // 0.5
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'(-2), "");              // 0.25
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'(-2), PY_TAG_INT, 128'(-3), "");            // -0.125
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd10, PY_TAG_INT, 128'(-1), "");             // 0.1
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd0, PY_TAG_INT, 128'(-1), "");              // ZeroDivision
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd1, PY_TAG_INT, 128'(-5), "");              // 1.0
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'(-1), PY_TAG_INT, 128'(-5), "");            // -1.0
        run_case(PY_ALU_POWER, PY_TAG_BOOL, 128'd1, PY_TAG_INT, 128'(-7), "");             // 1.0
        run_case(PY_ALU_POWER, PY_TAG_BOOL, 128'd0, PY_TAG_INT, 128'(-7), "");             // ZeroDivision
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'(-1074), "");           // 5e-324
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2, PY_TAG_INT, 128'(-1075), "");           // 0.0
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd3, PY_TAG_INT, 128'(-700), "");            // 0.0 (underflow)
        run_case(PY_ALU_POWER, PY_TAG_INT, {64'd0, 64'h8000_0000_0000_0000}, PY_TAG_INT, 128'(-1), ""); // -2^-63

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
        // float ** float on the log / exp unit
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 2 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4020_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FD5_5555_5555_5555}, "");   // 8 ** (1/3)
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4024_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4073_4800_0000_0000}, "");   // 10 ** 308.5 -> Overflow
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4024_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4073_4000_0000_0000}, "");   // 10 ** 308 (near DBL_MAX)
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC090_C800_0000_0000}, "");   // 2 ** -1074 (min subnormal)
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC090_CC00_0000_0000}, "");   // 2 ** -1075 -> 0.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 0.5 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hC000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC008_0000_0000_0000}, "");   // (-2) ** -3 = -0.125
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hC020_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FD5_5555_5555_5555}, "");   // (-8) ** (1/3) -> complex: trap
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0001},
                 PY_TAG_FLOAT, {64'd0, 64'h430C_6BF5_2634_0000}, "");   // (1+2^-52) ** 1e15
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'hC3AB_C16D_674E_C800}, "");   // (1-2^-53) ** -1e18
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // DBL_MAX ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 5e-324 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0001}, "");   // 2 ** 5e-324 = 1.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h43F0_0000_0000_0000}, "");   // 2 ** 2^64 -> Overflow
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h43F0_0000_0000_0000}, "");   // 0.5 ** 2^64 = 0.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hBFF8_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4034_0000_0000_0000}, "");   // (-1.5) ** 20
        // x ** 0.5 on the square-root path: exact roots, odd / even exponents, subnormals
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4010_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 4 ** 0.5 = 2
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4022_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 9 ** 0.5 = 3
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4020_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 8 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FD0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 0.25 ** 0.5 = 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0001},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // (1 + 2^-52) ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FEF_FFFF_FFFF_FFFF},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // (1 - 2^-53) ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h0000_0000_0000_0002},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 1e-323 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h0008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // DBL_MIN/2 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h0010_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // DBL_MIN ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h7FE0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // 2^1023 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_INT, 128'd2,
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // int 2 ** 0.5
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h8000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // -0.0 ** 0.5 = 0.0
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hC010_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "");   // -4 ** 0.5 -> complex: trap
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'hBFF8_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4035_0000_0000_0000}, "");   // (-1.5) ** 21
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
        // Complex / with an infinite operand: CPython 3.14 recovery
        // (inf+0j)/(1+1j) = inf-infj ; infj/(2+0j) = nan+infj (no recovery, one NaN)
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000}, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h7FF0_0000_0000_0000, 64'h0000_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h4000_0000_0000_0000}, "");
        // (1+2j)/(inf+0j) = 0j ; (1+2j)/(inf+infj) = 0j ; (-1-2j)/(inf+0j) = -0-0j
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h7FF0_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'hC000_0000_0000_0000, 64'hBFF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
        // (inf+infj)/(1-1j): inf*(1 + -1) -> inf*0 = nan real, inf*(1 - -1) = inf imag
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h7FF0_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'hBFF0_0000_0000_0000, 64'h3FF0_0000_0000_0000}, "");
        // both infinite / NaN operand: stays nan+nanj
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000}, "");
        // (3+2j)/(-inf+nanj): the NaN component acts as +-0 -> -0-0j
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h4008_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h7FF8_0000_0000_0000, 64'hFFF0_0000_0000_0000}, "");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h4008_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'hFFF8_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
        // huge finite numerator over infinite denominator: sum overflows, 0*inf = nan
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h7FEF_FFFF_FFFF_FFFF, 64'h7FEF_FFFF_FFFF_FFFF},
                 PY_TAG_COMPLEX, {64'h7FF0_0000_0000_0000, 64'h7FF0_0000_0000_0000}, "");
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
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hBFF0_0000_0000_0000}, "probe FLOAT 3.0**-1");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000}, "probe FLOAT 3.0**3 (unit)");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000}, "probe FLOAT 3.0**0.5 (sqrt)");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4000_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FD0_0000_0000_0000}, "probe FLOAT 2.0**0.25 (2^n base)");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FD0_0000_0000_0000}, "probe FLOAT 3.0**0.25 (unit)");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h3FE0_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h43F0_0000_0000_0000}, "probe FLOAT 0.5**2^64 (underflow)");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'h3FF0_0000_0000_0000}, "probe FLOAT 3.0**1");
        run_case(PY_ALU_POWER, PY_TAG_FLOAT, {64'd0, 64'h4008_0000_0000_0000},
                 PY_TAG_FLOAT, {64'd0, 64'hC000_0000_0000_0000}, "probe FLOAT 3.0**-2");
        run_case(PY_ALU_ADD, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX +");
        run_case(PY_ALU_MUL, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX *");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h4010_0000_0000_0000, 64'h4008_0000_0000_0000}, "probe COMPLEX /");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h4000_0000_0000_0000}, "probe COMPLEX inf/, no recovery");
        run_case(PY_ALU_TRUE_DIV, PY_TAG_COMPLEX, {64'h0000_0000_0000_0000, 64'h7FF0_0000_0000_0000},
                 PY_TAG_COMPLEX, {64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000}, "probe COMPLEX inf/, recovery");
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
        pow_checked = 0;
        for (int i = 0; i < 32; i++) trap_count[i] = 0;
        pow_exact = 0;
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
        pow_pairs(iters / 3);
        complex_pairs(iters / 2);

        back_to_back = 1'b1;
        directed();
        int_pairs(iters / 2);
        float_pairs(iters / 2);
        pow_pairs(iters / 6);
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
        $display("Traps seen (expected by the reference and raised by the hardware)");
        for (int i = 1; i < 32; i++) begin
            if (trap_count[i] != 0) $display("  code %2d %-14s %6d", i, trap_name(5'(i)), trap_count[i]);
        end
        $display("");
        if (errors != 0) begin
            $display("float ** : %0d of %0d results identical to libm pow()", pow_exact, pow_checked);
            $display("FAIL: %0d of %0d ALU checks failed (seed %0d)", errors, checks, seed);
            $fatal(1);
        end
        $display("float ** : %0d of %0d results identical to libm pow()", pow_exact, pow_checked);
        $display("PASS: %0d ALU unit checks against the CPython reference (seed %0d)", checks, seed);
        $finish;
    end
endmodule
