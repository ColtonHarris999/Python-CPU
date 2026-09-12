`include "pycore_defs.svh"

// Standalone STRACC + RAM (planning/string_accelerator_plan.md §10.1).
module tb_str_accel;
    localparam int DATA_WIDTH = 128;
    localparam int ADDR_WIDTH = 32;
    localparam int LINE_BYTES = 64;

    logic clk, rst_n;
    int   t_first;

    logic cmd_valid, cmd_ready, res_valid, res_trap;
    logic [5:0]  cmd_op;
    logic [3:0]  cmd_var;
    logic [PYCORE_ENTRY_WIDTH-1:0] cmd_a, cmd_b, cmd_c, res_entry;
    logic [31:0] cmd_heap, res_heap;
    logic [4:0]  res_code;

    logic acc_req, acc_we, acc_line, acc_ack, acc_last, acc_fault;
    logic [15:0] acc_wstrb;
    logic [31:0] acc_addr;
    logic [127:0] acc_wdata, acc_rdata;
    logic [LINE_BYTES*8-1:0] acc_wline;
    logic [31:0] bytes_scanned, bytes_written, cmd_count;

    logic tb_drv;
    logic tb_req, tb_we, ram_req, ram_we, ram_ack, ram_last, ram_fault;
    logic [15:0] tb_wstrb, ram_wstrb;
    logic [31:0] tb_addr, ram_addr;
    logic [127:0] tb_wdata, ram_wdata, ram_rdata;
    logic [LINE_BYTES*8-1:0] ram_wline;

    assign ram_req   = tb_drv ? tb_req   : acc_req;
    assign ram_we    = tb_drv ? tb_we    : acc_we;
    assign ram_wstrb = tb_drv ? tb_wstrb : acc_wstrb;
    assign ram_addr  = tb_drv ? tb_addr  : acc_addr;
    assign ram_wdata = tb_drv ? tb_wdata : acc_wdata;
    assign ram_wline = '0;
    assign acc_ack   = ram_ack;
    assign acc_last  = ram_last;
    assign acc_fault = ram_fault;
    assign acc_rdata = ram_rdata;

    pycore_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .RAM_BYTES(PYCORE_RAM_BYTES),
        .T_BEAT(1),
        .DATA_LIMIT(PYCORE_DMEM_BYTES),
        .DMEM_HEX(""),
        .PROG_HEX(""),
        .CODE_RAM_HEX(""),
        .DMEM_PLUSARG(""),
        .PROG_PLUSARG(""),
        .CODE_RAM_PLUSARG("")
    ) ram (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .t_first_i(t_first),
        .req_i(ram_req),
        .we_i(ram_we),
        .line_i(1'b0),
        .wstrb_i(ram_wstrb),
        .addr_i(ram_addr),
        .wdata_i(ram_wdata),
        .wline_i(ram_wline),
        .ack_o(ram_ack),
        .last_o(ram_last),
        .rdata_o(ram_rdata),
        .fault_o(ram_fault)
    );

    pycore_str_accel dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .cmd_valid_i(cmd_valid),
        .cmd_ready_o(cmd_ready),
        .cmd_op_i(cmd_op),
        .cmd_var_i(cmd_var),
        .cmd_a_i(cmd_a),
        .cmd_b_i(cmd_b),
        .cmd_c_i(cmd_c),
        .cmd_heap_ptr_i(cmd_heap),
        .res_valid_o(res_valid),
        .res_entry_o(res_entry),
        .res_heap_ptr_o(res_heap),
        .res_trap_o(res_trap),
        .res_trap_code_o(res_code),
        .req_o(acc_req),
        .we_o(acc_we),
        .line_o(acc_line),
        .wstrb_o(acc_wstrb),
        .addr_o(acc_addr),
        .wdata_o(acc_wdata),
        .wline_o(acc_wline),
        .ack_i(acc_ack),
        .last_i(acc_last),
        .rdata_i(acc_rdata),
        .fault_i(acc_fault),
        .bytes_scanned_o(bytes_scanned),
        .bytes_written_o(bytes_written),
        .cmd_count_o(cmd_count)
    );

    always #5 clk = ~clk;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] mk_short(input string s);
        logic [119:0] payload;
        int unsigned i;
        payload = '0;
        for (i = 0; i < s.len(); i++)
            payload[119-(i*8) -: 8] = s[i];
        mk_short = pycore_make_short_str_entry(s.len()[3:0], payload);
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] mk_int(input int n);
        mk_int = pycore_stracc_make_int(n);
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] mk_none();
        mk_none = pycore_make_control(PY_CTL_NONE);
    endfunction

    task automatic wait_ack();
        int cycles;
        cycles = 0;
        while (!ram_ack) begin
            @(negedge clk);
            cycles++;
            check(cycles < 64, "ram ack timeout");
        end
    endtask

    task automatic ram_write(input logic [31:0] addr, input logic [127:0] data);
        tb_drv = 1'b1;
        @(negedge clk);
        tb_req = 1'b1;
        tb_we = 1'b1;
        tb_wstrb = 16'hFFFF;
        tb_addr = addr;
        tb_wdata = data;
        @(negedge clk);
        tb_req = 1'b0;
        tb_we = 1'b0;
        wait_ack();
        @(negedge clk);
        tb_drv = 1'b0;
    endtask

    task automatic ram_read(input logic [31:0] addr, output logic [127:0] data);
        tb_drv = 1'b1;
        @(negedge clk);
        tb_req = 1'b1;
        tb_we = 1'b0;
        tb_wstrb = 16'h0;
        tb_addr = addr;
        tb_wdata = '0;
        @(negedge clk);
        tb_req = 1'b0;
        wait_ack();
        data = ram_rdata;
        @(negedge clk);
        tb_drv = 1'b0;
    endtask

    task automatic expect_seq_short(
        input logic is_list,
        input string want[$],
        input string msg
    );
        logic [127:0] header, slot, val, tagw;
        logic [31:0] obj, obuf, n, i;
        logic [PYCORE_ENTRY_WIDTH-1:0] el, exp;
        check(!res_trap, {msg, ": trapped"});
        if (is_list) begin
            check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_MUT_COLLEC,
                  {msg, ": not list"});
            obj = pycore_mut_addr(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB])[31:0];
            ram_read(obj, header);
            n = header[31:0];
            ram_read(obj + 32'd16, slot);
            obuf = slot[31:0];
        end else begin
            check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_TUPLE,
                  {msg, ": not tuple"});
            n = res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB][95:64];
            obuf = res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB][31:0];
        end
        check(n == want.size(), {msg, ": length"});
        for (i = 0; i < n; i++) begin
            ram_read(obuf + (i << 5), val);
            ram_read(obuf + (i << 5) + 32'd16, tagw);
            el = pycore_make_entry(tagw[3:0], val);
            exp = mk_short(want[i]);
            check(el == exp, {msg, ": elem mismatch"});
        end
    endtask

    task automatic issue(
        input logic [5:0] op,
        input logic [3:0] var_,
        input logic [PYCORE_ENTRY_WIDTH-1:0] a,
        input logic [PYCORE_ENTRY_WIDTH-1:0] b,
        input logic [PYCORE_ENTRY_WIDTH-1:0] c,
        input logic [31:0] heap
    );
        int cycles;
        @(negedge clk);
        check(cmd_ready, "cmd_ready low");
        cmd_op = op;
        cmd_var = var_;
        cmd_a = a;
        cmd_b = b;
        cmd_c = c;
        cmd_heap = heap;
        cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;
        cycles = 0;
        while (!res_valid) begin
            @(negedge clk);
            cycles++;
            check(cycles < 100000, "STRACC timeout");
        end
    endtask

    task automatic expect_short(input string want, input string msg);
        logic [PYCORE_ENTRY_WIDTH-1:0] exp;
        exp = mk_short(want);
        check(!res_trap, {msg, ": trapped"});
        check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_SHORT_STR,
              {msg, ": not SHORT"});
        check(res_entry == exp, {msg, ": payload mismatch"});
    endtask

    task automatic plant_units(
        input logic [31:0] addr,
        input logic [31:0] nchars,
        input logic [2:0]  kind,
        input logic [31:0] units [0:7],
        output logic [PYCORE_ENTRY_WIDTH-1:0] handle
    );
        logic [31:0] nbytes, digest, i, bi, off;
        logic [127:0] word, header;
        logic [7:0]   payload [0:63];
        nbytes = nchars * {29'b0, kind};
        digest = PYCORE_STRACC_FNV_OFFSET;
        for (i = 0; i < 64; i++)
            payload[i] = 8'h00;
        off = 0;
        for (i = 0; i < nchars; i++) begin
            for (bi = 0; bi < {29'b0, kind}; bi++) begin
                payload[off] = units[i][8*bi +: 8];
                digest = pycore_stracc_fnv_step(digest, payload[off]);
                off++;
            end
        end
        header = pycore_stracc_pack_header(nchars, nbytes[23:0], kind, digest, 6'd0);
        ram_write(addr, header);
        word = '0;
        for (i = 0; i < nbytes; i++) begin
            word[8*(i[3:0]) +: 8] = payload[i];
            if ((i[3:0] == 4'd15) || (i + 32'd1 == nbytes)) begin
                ram_write(addr + 32'd16 + {i[31:4], 4'b0}, word);
                word = '0;
            end
        end
        handle = pycore_make_entry(PY_TAG_LONG_STR,
            pycore_stracc_pack_handle(addr, nchars, nbytes[23:0], kind, digest, 6'd0));
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        t_first = 1;
        cmd_valid = 1'b0;
        cmd_op = '0;
        cmd_var = '0;
        cmd_a = '0;
        cmd_b = '0;
        cmd_c = '0;
        cmd_heap = PYCORE_HEAP_BASE;
        tb_drv = 1'b0;
        tb_req = 1'b0;
        tb_we = 1'b0;
        tb_wstrb = '0;
        tb_addr = '0;
        tb_wdata = '0;
        #12;
        rst_n = 1'b1;
        @(negedge clk);

        // Empty concat identity.
        issue(PY_SA_CONCAT, 0, mk_short(""), mk_short("hello"), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("hello", "empty+hello");

        issue(PY_SA_CONCAT, 0, mk_short("hello"), mk_short(" world"), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("hello world", "hello+world");

        // Crosses 15 → LONG.
        issue(PY_SA_CONCAT, 0, mk_short("abcdefghij"), mk_short("klmnop"),
              mk_none(), PYCORE_HEAP_BASE);
        check(!res_trap, "16-byte concat trapped");
        check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_LONG_STR,
              "16-byte concat not LONG");
        check(pycore_stracc_nchars(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB]) == 32'd16,
              "16-byte nchars");
        check(pycore_stracc_kind_width(pycore_stracc_kind_field(
              res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB])) == 3'd1, "16-byte kind");

        issue(PY_SA_CMP, 0, mk_short("abc"), mk_short("abd"), mk_none(),
              PYCORE_HEAP_BASE);
        check(!res_trap, "cmp trap");
        check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_INT, "cmp tag");
        check(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB] == {128{1'b1}}, "cmp -1");

        issue(PY_SA_CMP, 0, mk_short("abc"), mk_short("abc"), mk_none(),
              PYCORE_HEAP_BASE);
        check(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB] == 128'd0, "cmp 0");

        issue(PY_SA_SEARCH, PY_SA_FIND, mk_short("banana"), mk_short("ana"),
              mk_none(), PYCORE_HEAP_BASE);
        check(res_entry[31:0] == 32'd1, "find ana");

        issue(PY_SA_SEARCH, PY_SA_RFIND, mk_short("banana"), mk_short("ana"),
              mk_none(), PYCORE_HEAP_BASE);
        check(res_entry[31:0] == 32'd3, "rfind ana");

        issue(PY_SA_SEARCH, PY_SA_COUNT, mk_short("banana"), mk_short("ana"),
              mk_none(), PYCORE_HEAP_BASE);
        check(res_entry[31:0] == 32'd1, "count ana");

        issue(PY_SA_SEARCH, PY_SA_FIND, mk_short("ab"), mk_short(""),
              mk_none(), PYCORE_HEAP_BASE);
        check(res_entry[31:0] == 32'd0, "find empty");

        issue(PY_SA_CHAR_AT, 0, mk_short("hello"), mk_int(1), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("e", "char_at");

        issue(PY_SA_CHAR_AT, 0, mk_short("hi"), mk_int(5), mk_none(),
              PYCORE_HEAP_BASE);
        check(res_trap && res_code == PY_TRAP_MEM_FAULT, "char_at oob");

        issue(PY_SA_ITER_NEXT, 0, mk_short("ab"), mk_int(2), mk_none(),
              PYCORE_HEAP_BASE);
        check(!res_trap, "iter end trap");
        check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_CONTROL,
              "iter end tag");

        issue(PY_SA_HASH, 0, mk_short("hello"), mk_int(0), mk_none(),
              PYCORE_HEAP_BASE);
        check(res_entry[31:0] == pycore_stracc_hash_short(mk_short("hello")[127:0]),
              "hash hello");

        issue(PY_SA_REPEAT, 0, mk_short("xy"), mk_int(3), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("xyxyxy", "repeat");

        issue(PY_SA_SLICE, 0, mk_short("abcdefghij"), mk_int(2), mk_int(5),
              PYCORE_HEAP_BASE);
        expect_short("cde", "slice");

        issue(PY_SA_PAD, PY_SA_PAD_BOTH, mk_short("ab"), mk_int(6), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("  ab  ", "center");

        issue(PY_SA_CONCAT, 0, mk_int(1), mk_short("x"), mk_none(),
              PYCORE_HEAP_BASE);
        check(res_trap && res_code == PY_TRAP_TYPE, "type concat");

        issue(PY_SA_REPEAT, 0, mk_short("xy"), mk_int(10000), mk_int(0),
              PYCORE_HEAP_LIMIT - 32'd16);
        check(res_trap && res_code == PY_TRAP_MEM_FAULT, "oom");
        check(res_heap == (PYCORE_HEAP_LIMIT - 32'd16), "oom heap moved");

        begin
            logic [31:0] u_alpha [0:7];
            logic [31:0] u_emoji [0:7];
            logic [PYCORE_ENTRY_WIDTH-1:0] h_alpha, h_emoji;
            u_alpha[0] = 32'h03B1; // α
            u_emoji[0] = 32'h1F642; // 🙂 is U+1F642? actually U+1F642 is slightly smiling; 🙂 is U+1F642... wait 🙂 is U+1F642 no: slightly smiling face is U+1F642, 🙂 is U+1F642. Python '🙂' is U+1F642? Let me use U+1F600 😀 to be safe... model uses 🙂. ord('🙂') = 0x1F642.
            plant_units(PYCORE_HEAP_BASE, 32'd1, 3'd2, u_alpha, h_alpha);
            plant_units(PYCORE_HEAP_BASE + 32'h40, 32'd1, 3'd4, u_emoji, h_emoji);

            issue(PY_SA_SEARCH, PY_SA_FIND, mk_short("abc"), h_alpha, mk_none(),
                  PYCORE_HEAP_BASE + 32'h80);
            check(!res_trap, "kind reject trap");
            check(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB] == {128{1'b1}},
                  "kind reject find");

            issue(PY_SA_CONCAT, 0, mk_short("ab"), h_alpha, mk_none(),
                  PYCORE_HEAP_BASE + 32'h80);
            check(!res_trap, "kind2 concat trap");
            check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_LONG_STR,
                  "kind2 concat tag");
            check(pycore_stracc_kind_width(pycore_stracc_kind_field(
                  res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB])) == 3'd2,
                  "kind2 concat kind");
            check(pycore_stracc_nchars(res_entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB]) == 32'd3,
                  "kind2 concat nchars");

            issue(PY_SA_CMP, 0, h_alpha, mk_short("a"), mk_none(),
                  PYCORE_HEAP_BASE + 32'h80);
            check(!res_trap, "kind2 cmp trap");
            check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_INT, "kind2 cmp tag");

            issue(PY_SA_SEARCH, PY_SA_CONTAINS, mk_short("hello"), mk_short("ll"),
                  mk_none(), PYCORE_HEAP_BASE);
            check(res_entry[0] == 1'b1, "contains ll");

            issue(PY_SA_SEARCH, PY_SA_STARTSWITH, mk_short("hello"), mk_short("he"),
                  mk_none(), PYCORE_HEAP_BASE);
            check(res_entry[0] == 1'b1, "startswith he");

            issue(PY_SA_SEARCH, PY_SA_ENDSWITH, mk_short("hello"), mk_short("lo"),
                  mk_none(), PYCORE_HEAP_BASE);
            check(res_entry[0] == 1'b1, "endswith lo");

            issue(PY_SA_REPLACE, 0, mk_short("banana"), mk_short("ana"),
                  mk_short("XY"), PYCORE_HEAP_BASE);
            check(!res_trap, "replace trap");
            check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_SHORT_STR,
                  "replace tag");
        end

        issue(PY_SA_TRIM, PY_SA_TRIM_BOTH, mk_short("  hi  "), mk_none(),
              mk_none(), PYCORE_HEAP_BASE);
        expect_short("hi", "strip");

        issue(PY_SA_MAP, PY_SA_MAP_UPPER, mk_short("Ab"), mk_none(),
              mk_none(), PYCORE_HEAP_BASE);
        expect_short("AB", "upper");

        issue(PY_SA_CLASSIFY, PY_SA_IS_DIGIT, mk_short("12"), mk_none(),
              mk_none(), PYCORE_HEAP_BASE);
        check(!res_trap, "isdigit trap");
        check(res_entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB] == PY_TAG_BOOL, "isdigit tag");
        check(res_entry[0] == 1'b1, "isdigit 12");

        issue(PY_SA_ZFILL, 0, mk_short("42"), mk_int(5), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("00042", "zfill");

        issue(PY_SA_AFFIX, PY_SA_AFFIX_PREFIX, mk_short("foobar"), mk_short("foo"),
              mk_none(), PYCORE_HEAP_BASE);
        expect_short("bar", "removeprefix");

        begin
            logic [31:0] obj, obuf;
            logic [PYCORE_ENTRY_WIDTH-1:0] lst, s0, s1;
            obj = 32'h0000_2000;
            obuf = 32'h0000_2040;
            s0 = mk_short("a");
            s1 = mk_short("b");
            ram_write(obj, {64'd2, 64'd2});
            ram_write(obj + 32'd16, {64'd0, 64'(obuf)});
            ram_write(obuf, s0[PYCORE_VAL_MSB:PYCORE_VAL_LSB]);
            ram_write(obuf + 32'd16, {124'b0, PY_TAG_SHORT_STR});
            ram_write(obuf + 32'd32, s1[PYCORE_VAL_MSB:PYCORE_VAL_LSB]);
            ram_write(obuf + 32'd48, {124'b0, PY_TAG_SHORT_STR});
            lst = pycore_make_mut(PY_MUT_LIST, {32'd0, obj}, 1'b0);
            issue(PY_SA_JOIN, 0, mk_short("-"), lst, mk_none(),
                  PYCORE_HEAP_BASE);
            expect_short("a-b", "join list");
        end

        issue(PY_SA_JOIN, 0, mk_short("-"), mk_short("ab"), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("a-b", "join str");

        issue(PY_SA_EXPANDTABS, 0, mk_short("a\tb"), mk_int(4), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("a   b", "expandtabs 4");

        issue(PY_SA_EXPANDTABS, 0, mk_short("hello"), mk_none(), mk_none(),
              PYCORE_HEAP_BASE);
        expect_short("hello", "expandtabs identity");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_PARTITION, mk_short("a,b,c"), mk_short(","),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b0, '{"a", ",", "b,c"}, "partition");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_RPARTITION, mk_short("a,b,c"), mk_short(","),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b0, '{"a,b", ",", "c"}, "rpartition");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_PARTITION, mk_short("hello"), mk_short("x"),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b0, '{"hello", "", ""}, "partition miss");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_FWD, mk_short("a b c"), mk_none(), mk_none(),
              PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a", "b", "c"}, "split ws");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_FWD, mk_short("a,b,c"), mk_short(","),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a", "b", "c"}, "split sep");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_REV, mk_short("a,b,c,d"), mk_short(","),
              mk_int(1), PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a,b,c", "d"}, "rsplit 1");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_FWD, mk_short("a  b  c"), mk_none(),
              mk_int(1), PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a", "b  c"}, "split maxsplit 1");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_LINES, mk_short("a\nb\n"), mk_none(),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a", "b"}, "splitlines");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_LINES, mk_short("a\nb"), mk_int(1),
              mk_none(), PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{"a\n", "b"}, "splitlines keepends");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_FWD, mk_short(""), mk_none(), mk_none(),
              PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{}, "split empty ws");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_FWD, mk_short(""), mk_short(","), mk_none(),
              PYCORE_HEAP_BASE);
        expect_seq_short(1'b1, '{""}, "split empty sep");

        issue(PY_SA_SPLIT, PY_SA_SPLIT_PARTITION, mk_short("hello"), mk_short(""),
              mk_none(), PYCORE_HEAP_BASE);
        check(res_trap && res_code == PY_TRAP_TYPE, "partition empty sep");

        $display("tb_str_accel PASS");
        $finish;
    end
endmodule
