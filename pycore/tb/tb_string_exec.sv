`include "pycore_defs.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
module tb_string_exec;
    localparam int STRING_MEM_BYTES = 8192;
    localparam int STRING_MAX_LEN = 64;
    localparam longint unsigned STRING_RUNTIME_BASE = 64'd1024;

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
    longint unsigned last_long_addr;

    pycore_exec #(
        .STRING_MEM_BYTES(STRING_MEM_BYTES),
        .STRING_MAX_LEN(STRING_MAX_LEN),
        .STRING_RUNTIME_BASE(STRING_RUNTIME_BASE)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .valid_i(valid),
        .alu_op_i(alu_op),
        .rs1_i(rs1),
        .rs2_i(rs2),
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

    function automatic string make_ascii(input int count, input int seed);
        string out;
        int i;
        begin
            out = "";
            for (i = 0; i < count; i++) begin
                out = {out, byte'(((seed + i) % 26) + 8'd97)};
            end
            make_ascii = out;
        end
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] short_entry(input string value);
        logic [119:0] payload;
        logic [3:0] short_len;
        int i;
        begin
            payload = '0;
            short_len = value.len();
            for (i = 0; (i < value.len()) && (i < PYCORE_SHORT_STR_MAX_BYTES); i++) begin
                payload[119-(i*8)-:8] = value[i];
            end
            short_entry = pycore_make_short_str_entry(short_len, payload);
        end
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] long_entry(
        input longint unsigned size,
        input longint unsigned addr
    );
        begin
            long_entry = pycore_make_long_str_entry(size[63:0], addr[63:0]);
        end
    endfunction

    task automatic preload_string(input longint unsigned addr, input string value);
        int i;
        int unsigned idx;
        begin
            for (i = 0; i < value.len(); i++) begin
                idx = int'(addr + i);
                dut.string_mem[idx] = value[i];
            end
        end
    endtask

    task automatic run_concat(
        input logic [PYCORE_ENTRY_WIDTH-1:0] lhs,
        input logic [PYCORE_ENTRY_WIDTH-1:0] rhs,
        input bit expect_trap,
        input logic [4:0] expected_trap_code,
        input string expected_value
    );
        int i;
        logic [3:0] out_tag;
        logic [PYCORE_VAL_WIDTH-1:0] out_val;
        longint unsigned out_len;
        longint unsigned out_addr;
        logic [3:0] expected_short_len;
        int unsigned mem_idx;
        begin
            rs1 = lhs;
            rs2 = rhs;
            alu_op = PY_ALU_ADD;
            #1;
            tests_run++;

            check(!stall, "string concat should not stall");
            if (expect_trap) begin
                check(trap, "concat should trap");
                check(trap_code == expected_trap_code, "concat trap code mismatch");
            end else begin
                check(!trap, "concat should not trap");
                out_tag = pycore_get_tag(result);
                out_val = pycore_get_val(result);
                if (expected_value.len() <= PYCORE_SHORT_STR_MAX_BYTES) begin
                    expected_short_len = expected_value.len();
                    check(out_tag == PY_TAG_SHORT_STR, "short concat should produce short tag");
                    check(pycore_short_str_size(out_val) == expected_short_len,
                          "short concat size mismatch");
                    for (i = 0; i < expected_value.len(); i++) begin
                        check(pycore_short_str_byte(out_val, i) == expected_value[i],
                              "short concat byte mismatch");
                    end
                end else begin
                    check(out_tag == PY_TAG_LONG_STR, "long concat should produce long tag");
                    out_len = pycore_long_str_size(out_val);
                    out_addr = pycore_long_str_addr(out_val);
                    check(out_len == expected_value.len(), "long concat size mismatch");
                    check(out_addr >= STRING_RUNTIME_BASE, "long concat address should be runtime heap");
                    check(out_addr >= last_long_addr, "long concat address should not move backwards");
                    @(posedge clk);
                    #1;
                    for (i = 0; i < expected_value.len(); i++) begin
                        mem_idx = int'(out_addr + i);
                        check(dut.string_mem[mem_idx] == expected_value[i], "long concat byte mismatch");
                    end
                    last_long_addr = out_addr + out_len;
                end
            end
        end
    endtask

    initial begin
        string a;
        string b;
        string c;
        string d;
        string long_a;
        string long_b;
        string long_c;
        string long_d;
        int len_a;
        int len_b;

        clk = 1'b0;
        rst_n = 1'b0;
        valid = 1'b0;
        alu_op = PY_ALU_ADD;
        rs1 = '0;
        rs2 = '0;
        tests_run = 0;
        last_long_addr = STRING_RUNTIME_BASE;
        #20;
        rst_n = 1'b1;
        valid = 1'b1;
        #1;

        long_a = make_ascii(20, 1);
        long_b = make_ascii(23, 9);
        long_c = make_ascii(40, 2);
        long_d = make_ascii(30, 11);
        preload_string(0, long_a);
        preload_string(64, long_b);
        preload_string(128, long_c);
        preload_string(256, long_d);

        // Short-string matrix across all legal sizes.
        for (len_a = 0; len_a <= PYCORE_SHORT_STR_MAX_BYTES; len_a++) begin
            for (len_b = 0; len_b <= PYCORE_SHORT_STR_MAX_BYTES; len_b++) begin
                a = make_ascii(len_a, len_a);
                b = make_ascii(len_b, len_b + 7);
                run_concat(
                    short_entry(a),
                    short_entry(b),
                    1'b0,
                    PY_TRAP_NONE,
                    {a, b}
                );
            end
        end

        // Cross short/long and long/long concatenations.
        c = make_ascii(8, 3);
        d = make_ascii(7, 17);
        run_concat(short_entry(c), long_entry(long_a.len(), 0), 1'b0, PY_TRAP_NONE, {c, long_a});
        run_concat(long_entry(long_a.len(), 0), short_entry(d), 1'b0, PY_TRAP_NONE, {long_a, d});
        run_concat(long_entry(long_a.len(), 0), long_entry(long_b.len(), 64), 1'b0, PY_TRAP_NONE,
                   {long_a, long_b});
        run_concat(short_entry(make_ascii(15, 4)), short_entry(make_ascii(15, 20)), 1'b0, PY_TRAP_NONE,
                   {make_ascii(15, 4), make_ascii(15, 20)});

        // Oversized concatenation must trap the CPU.
        run_concat(
            long_entry(long_c.len(), 128),
            long_entry(long_d.len(), 256),
            1'b1,
            PY_TRAP_MEM_FAULT,
            ""
        );

        check(tests_run == ((PYCORE_SHORT_STR_MAX_BYTES + 1) * (PYCORE_SHORT_STR_MAX_BYTES + 1)) + 5,
              "unexpected number of string concat tests");

        $display("PASS: string concat matrix complete (%0d cases)", tests_run);
        $finish;
    end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on UNUSEDSIGNAL */
