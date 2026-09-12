`include "pycore_defs.svh"

// String Accelerator (planning/string_accelerator_plan.md P5a).
// Own dmem master. Not wired into the core yet.
module pycore_str_accel #(
    parameter logic [31:0] HEAP_LIMIT = PYCORE_HEAP_LIMIT
) (
    input  logic clk_i,
    input  logic rst_n_i,

    input  logic                          cmd_valid_i,
    output logic                          cmd_ready_o,
    input  logic [5:0]                    cmd_op_i,
    input  logic [3:0]                    cmd_var_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_a_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_b_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_c_i,
    input  logic [31:0]                   cmd_heap_ptr_i,

    output logic                          res_valid_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] res_entry_o,
    output logic [31:0]                   res_heap_ptr_o,
    output logic                          res_trap_o,
    output logic [4:0]                    res_trap_code_o,

    output logic                          req_o,
    output logic                          we_o,
    output logic                          line_o,
    output logic [15:0]                   wstrb_o,
    output logic [31:0]                   addr_o,
    output logic [127:0]                  wdata_o,
    output logic [PYCORE_LINE_BYTES*8-1:0] wline_o,
    input  logic                          ack_i,
    input  logic                          last_i,
    input  logic [127:0]                  rdata_i,
    input  logic                          fault_i,

    output logic [31:0]                   bytes_scanned_o,
    output logic [31:0]                   bytes_written_o,
    output logic [31:0]                   cmd_count_o
);
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PREP,
        ST_MEM_ISSUE,
        ST_MEM_WAIT,
        ST_STEP,
        ST_DONE
    } state_e;

    typedef enum logic [2:0] {
        ENG_NONE,
        ENG_COPY,
        ENG_CMP,
        ENG_SEARCH,
        ENG_HASH,
        ENG_CHAR
    } eng_e;

    typedef enum logic [1:0] {
        SRC_A,
        SRC_B,
        SRC_FILL
    } src_e;

    typedef enum logic [1:0] {
        MEM_RD,
        MEM_WR_DST,
        MEM_WR_HDR
    } mem_e;

    state_e state_r;
    eng_e   eng_r;
    mem_e   mem_kind_r;
    src_e   src_sel_r;

    logic [5:0]  op_r;
    logic [3:0]  var_r;
    logic [3:0]  a_tag_r, b_tag_r, c_tag_r;
    logic [127:0] a_val_r, b_val_r, c_val_r;
    logic [31:0] heap_ptr_r;

    logic [PYCORE_ENTRY_WIDTH-1:0] res_entry_r;
    logic [31:0] res_heap_r;
    logic        res_trap_r;
    logic [4:0]  res_code_r;

    logic [31:0] bytes_scanned_r, bytes_written_r, cmd_count_r;

    logic        mem_we_r;
    logic [31:0] mem_addr_r;
    logic [127:0] mem_wdata_r;
    logic [15:0] mem_wstrb_r;

    logic [127:0] src_word_r;
    logic [31:0]  src_word_addr_r;
    logic         src_word_valid_r;
    logic [127:0] dst_word_r;
    logic [31:0]  dst_word_addr_r;
    logic         dst_word_dirty_r;
    logic [7:0]   short_bytes_r [0:14];

    logic [31:0] a_nchars_r, b_nchars_r;
    logic [2:0]  a_kind_r, b_kind_r;
    logic [31:0] a_addr_r, b_addr_r;
    logic        a_short_r, b_short_r;

    logic [31:0] dst_nchars_r;
    logic [2:0]  dst_kind_r;
    logic        dst_short_r;
    logic [31:0] dst_place_r;
    logic [31:0] dst_end_r;
    logic [31:0] dst_nbytes_r;
    logic [31:0] out_idx_r;
    logic [31:0] src_idx_r;
    logic [31:0] split_r;
    logic [31:0] left_pad_r;
    logic [31:0] right_start_r;
    logic [31:0] fill_unit_r;
    logic [31:0] hash_r;
    logic [5:0]  flags_r;
    logic [31:0] repeat_left_r;

    logic [31:0] cmp_idx_r;
    logic [31:0] hay_unit_r;
    logic        have_hay_r;

    logic [31:0] pos_r;
    logic [31:0] nlen_r;
    logic [31:0] match_i_r;
    logic [31:0] search_end_r;
    logic [31:0] search_start_r;
    logic [31:0] count_r;
    logic        rfind_r;

    wire a_is_str = (a_tag_r == PY_TAG_SHORT_STR) || (a_tag_r == PY_TAG_LONG_STR);
    wire b_is_str = (b_tag_r == PY_TAG_SHORT_STR) || (b_tag_r == PY_TAG_LONG_STR);
    wire a_is_int = (a_tag_r == PY_TAG_INT) || (a_tag_r == PY_TAG_BOOL);
    wire b_is_int = (b_tag_r == PY_TAG_INT) || (b_tag_r == PY_TAG_BOOL);
    wire c_is_int = (c_tag_r == PY_TAG_INT) || (c_tag_r == PY_TAG_BOOL);
    wire c_is_none = (c_tag_r == PY_TAG_CONTROL) &&
                     (pycore_ctl_id(c_val_r) == PY_CTL_NONE);
    wire b_is_none = (b_tag_r == PY_TAG_CONTROL) &&
                     (pycore_ctl_id(b_val_r) == PY_CTL_NONE);

    assign cmd_ready_o = (state_r == ST_IDLE);
    assign res_valid_o = (state_r == ST_DONE);
    assign res_entry_o = res_entry_r;
    assign res_heap_ptr_o = res_heap_r;
    assign res_trap_o = res_trap_r;
    assign res_trap_code_o = res_code_r;

    assign req_o   = (state_r == ST_MEM_ISSUE);
    assign we_o    = mem_we_r;
    assign line_o  = 1'b0;
    assign wstrb_o = mem_wstrb_r;
    assign addr_o  = mem_addr_r;
    assign wdata_o = mem_wdata_r;
    assign wline_o = '0;

    assign bytes_scanned_o = bytes_scanned_r;
    assign bytes_written_o = bytes_written_r;
    assign cmd_count_o     = cmd_count_r;

    function automatic logic [31:0] view_nchars(
        input logic [3:0] tag,
        input logic [127:0] val
    );
        if (tag == PY_TAG_SHORT_STR)
            view_nchars = {28'b0, pycore_short_str_size(val)};
        else
            view_nchars = pycore_stracc_nchars(val);
    endfunction

    function automatic logic [2:0] view_kind(
        input logic [3:0] tag,
        input logic [127:0] val
    );
        if (tag == PY_TAG_SHORT_STR)
            view_kind = 3'd1;
        else
            view_kind = pycore_stracc_kind_width(pycore_stracc_kind_field(val));
    endfunction

    function automatic logic signed [63:0] adj_idx(
        input logic signed [63:0] raw,
        input logic [31:0] nchars
    );
        logic signed [63:0] i;
        logic signed [63:0] n;
        n = signed'({32'b0, nchars});
        i = raw;
        if (i < 0)
            i = i + n;
        if (i < 0)
            i = 64'sd0;
        if (i > n)
            i = n;
        adj_idx = i;
    endfunction

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] pack_short_local();
        logic [119:0] payload;
        int unsigned i;
        payload = '0;
        for (i = 0; i < PYCORE_SHORT_STR_MAX_BYTES; i++) begin
            if (i < dst_nchars_r)
                payload[119-(i*8) -: 8] = short_bytes_r[i];
        end
        pack_short_local = pycore_make_short_str_entry(dst_nchars_r[3:0], payload);
    endfunction

    task automatic set_trap(input logic [4:0] code);
        res_trap_r <= 1'b1;
        res_code_r <= code;
        res_entry_r <= '0;
        res_heap_r <= heap_ptr_r;
        state_r <= ST_DONE;
    endtask

    task automatic set_res(
        input logic [PYCORE_ENTRY_WIDTH-1:0] entry,
        input logic [31:0] heap
    );
        res_trap_r <= 1'b0;
        res_code_r <= PY_TRAP_NONE;
        res_entry_r <= entry;
        res_heap_r <= heap;
        state_r <= ST_DONE;
    endtask

    task automatic issue_read(input logic [31:0] addr);
        mem_kind_r <= MEM_RD;
        mem_we_r <= 1'b0;
        mem_addr_r <= {addr[31:4], 4'b0};
        mem_wdata_r <= '0;
        mem_wstrb_r <= 16'h0;
        state_r <= ST_MEM_ISSUE;
    endtask

    task automatic issue_write(
        input logic [31:0] addr,
        input logic [127:0] data,
        input mem_e kind
    );
        mem_kind_r <= kind;
        mem_we_r <= 1'b1;
        mem_addr_r <= {addr[31:4], 4'b0};
        mem_wdata_r <= data;
        mem_wstrb_r <= 16'hFFFF;
        state_r <= ST_MEM_ISSUE;
    endtask

    always_ff @(posedge clk_i) begin
        logic signed [63:0] s64;
        logic signed [63:0] e64;
        logic [31:0] start_u, stop_u, pad, left, right;
        logic [2:0]  kmax;
        logic [31:0] nout, nbytes, obj_bytes, place, end_addr;
        logic [31:0] byte_addr, word_addr;
        logic [2:0]  skind;
        logic [31:0] saddr, sidx, nch;
        logic        sshort;
        logic [127:0] sval;
        logic [31:0] unit, u_a, u_b;
        logic [3:0]  boff;
        int unsigned bi;
        logic [31:0] next_hash;
        logic [127:0] next_word;
        logic [31:0] next_off;

        if (!rst_n_i) begin
            state_r <= ST_IDLE;
            eng_r <= ENG_NONE;
            res_trap_r <= 1'b0;
            res_code_r <= PY_TRAP_NONE;
            res_entry_r <= '0;
            res_heap_r <= '0;
            bytes_scanned_r <= '0;
            bytes_written_r <= '0;
            cmd_count_r <= '0;
            src_word_valid_r <= 1'b0;
            dst_word_dirty_r <= 1'b0;
            mem_we_r <= 1'b0;
            have_hay_r <= 1'b0;
        end else begin
            unique case (state_r)
                ST_IDLE: begin
                    res_trap_r <= 1'b0;
                    if (cmd_valid_i) begin
                        op_r <= cmd_op_i;
                        var_r <= cmd_var_i;
                        a_tag_r <= cmd_a_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                        a_val_r <= cmd_a_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                        b_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                        b_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                        c_tag_r <= cmd_c_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                        c_val_r <= cmd_c_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                        heap_ptr_r <= cmd_heap_ptr_i;
                        cmd_count_r <= cmd_count_r + 32'd1;
                        src_word_valid_r <= 1'b0;
                        dst_word_dirty_r <= 1'b0;
                        have_hay_r <= 1'b0;
                        state_r <= ST_PREP;
                    end
                end

                ST_PREP: begin
                    a_nchars_r <= view_nchars(a_tag_r, a_val_r);
                    b_nchars_r <= view_nchars(b_tag_r, b_val_r);
                    a_kind_r <= view_kind(a_tag_r, a_val_r);
                    b_kind_r <= view_kind(b_tag_r, b_val_r);
                    a_addr_r <= pycore_stracc_addr(a_val_r);
                    b_addr_r <= pycore_stracc_addr(b_val_r);
                    a_short_r <= (a_tag_r == PY_TAG_SHORT_STR);
                    b_short_r <= (b_tag_r == PY_TAG_SHORT_STR);
                    hash_r <= PYCORE_STRACC_FNV_OFFSET;
                    flags_r <= PYCORE_STRACC_FLAG_ALL_LOWER | PYCORE_STRACC_FLAG_ALL_UPPER;
                    out_idx_r <= 32'd0;
                    src_idx_r <= 32'd0;
                    cmp_idx_r <= 32'd0;
                    unique case (op_r)
                        PY_SA_CONCAT: begin
                            if (!a_is_str || !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(a_tag_r, a_val_r) == 32'd0)
                                set_res(cmd_entry(b_tag_r, b_val_r), heap_ptr_r);
                            else if (view_nchars(b_tag_r, b_val_r) == 32'd0)
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else begin
                                kmax = (view_kind(a_tag_r, a_val_r) > view_kind(b_tag_r, b_val_r))
                                     ? view_kind(a_tag_r, a_val_r)
                                     : view_kind(b_tag_r, b_val_r);
                                nout = view_nchars(a_tag_r, a_val_r) +
                                       view_nchars(b_tag_r, b_val_r);
                                split_r <= view_nchars(a_tag_r, a_val_r);
                                left_pad_r <= 32'd0;
                                right_start_r <= nout;
                                fill_unit_r <= 32'h20;
                                setup_copy(nout, kmax);
                            end
                        end
                        PY_SA_REPEAT: begin
                            if (!a_is_str || !b_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = pycore_stracc_int64(b_val_r);
                                if ((s64 <= 0) || (view_nchars(a_tag_r, a_val_r) == 32'd0))
                                    set_res(pycore_make_short_str_entry(4'd0, 120'd0),
                                            heap_ptr_r);
                                else if (s64 == 64'sd1)
                                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                                else if (s64 > 64'sd1_000_000)
                                    set_trap(PY_TRAP_MEM_FAULT);
                                else begin
                                    nout = view_nchars(a_tag_r, a_val_r) * s64[31:0];
                                    split_r <= 32'd0;
                                    left_pad_r <= 32'd0;
                                    right_start_r <= nout;
                                    repeat_left_r <= s64[31:0];
                                    fill_unit_r <= 32'h20;
                                    setup_copy(nout, view_kind(a_tag_r, a_val_r));
                                end
                            end
                        end
                        PY_SA_SLICE: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if ((!b_is_none && !b_is_int) || (!c_is_none && !c_is_int))
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                nch = view_nchars(a_tag_r, a_val_r);
                                start_u = b_is_none ? 32'd0
                                        : adj_idx(pycore_stracc_int64(b_val_r), nch)[31:0];
                                stop_u = c_is_none ? nch
                                       : adj_idx(pycore_stracc_int64(c_val_r), nch)[31:0];
                                nout = (stop_u > start_u) ? (stop_u - start_u) : 32'd0;
                                src_idx_r <= start_u;
                                split_r <= nout;
                                left_pad_r <= 32'd0;
                                right_start_r <= nout;
                                if (nout == 32'd0)
                                    set_res(pycore_make_short_str_entry(4'd0, 120'd0),
                                            heap_ptr_r);
                                else
                                    setup_copy(nout, view_kind(a_tag_r, a_val_r));
                            end
                        end
                        PY_SA_PAD: begin
                            if (!a_is_str || !b_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = pycore_stracc_int64(b_val_r);
                                nch = view_nchars(a_tag_r, a_val_r);
                                if (s64 <= signed'({32'b0, nch}))
                                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                                else begin
                                    unit = 32'h20;
                                    kmax = view_kind(a_tag_r, a_val_r);
                                    if (!c_is_none) begin
                                        if (!((c_tag_r == PY_TAG_SHORT_STR) ||
                                              (c_tag_r == PY_TAG_LONG_STR)))
                                            set_trap(PY_TRAP_TYPE);
                                        else if (view_nchars(c_tag_r, c_val_r) != 32'd1)
                                            set_trap(PY_TRAP_TYPE);
                                        else begin
                                            // Fill taken in STEP from C; space default here
                                            // if C is a 1-char short.
                                            if (c_tag_r == PY_TAG_SHORT_STR)
                                                unit = {24'b0, pycore_short_str_byte(c_val_r, 0)};
                                            kmax = (pycore_stracc_kind_of_unit(unit) > kmax)
                                                 ? pycore_stracc_kind_of_unit(unit) : kmax;
                                        end
                                    end
                                    pad = s64[31:0] - nch;
                                    unique case (var_r)
                                        PY_SA_PAD_LEFT: begin
                                            left = pad;
                                            right = 32'd0;
                                        end
                                        PY_SA_PAD_RIGHT: begin
                                            left = 32'd0;
                                            right = pad;
                                        end
                                        default: begin
                                            left = pad >> 1;
                                            right = pad - left;
                                        end
                                    endcase
                                    fill_unit_r <= unit;
                                    left_pad_r <= left;
                                    right_start_r <= left + nch;
                                    split_r <= left;
                                    nout = s64[31:0];
                                    if (!res_trap_r)
                                        setup_copy(nout, kmax);
                                end
                            end
                        end
                        PY_SA_CMP: begin
                            if (!a_is_str || !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if ((a_tag_r == PY_TAG_LONG_STR) &&
                                     (b_tag_r == PY_TAG_LONG_STR) &&
                                     (pycore_stracc_addr(a_val_r) ==
                                      pycore_stracc_addr(b_val_r)))
                                set_res(pycore_stracc_make_int(32'sd0), heap_ptr_r);
                            else begin
                                eng_r <= ENG_CMP;
                                cmp_idx_r <= 32'd0;
                                have_hay_r <= 1'b0;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_SEARCH: begin
                            if (!a_is_str || !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else
                                prep_search();
                        end
                        PY_SA_HASH: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (a_tag_r == PY_TAG_SHORT_STR)
                                set_res(pycore_make_entry(PY_TAG_INT,
                                    {96'b0, pycore_stracc_hash_short(a_val_r)}),
                                    heap_ptr_r);
                            else
                                set_res(pycore_make_entry(PY_TAG_INT,
                                    {96'b0, pycore_stracc_hash(a_val_r)}),
                                    heap_ptr_r);
                        end
                        PY_SA_CHAR_AT, PY_SA_ITER_NEXT: begin
                            if (!a_is_str || !b_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = pycore_stracc_int64(b_val_r);
                                nch = view_nchars(a_tag_r, a_val_r);
                                if (s64 < 0)
                                    s64 = s64 + signed'({32'b0, nch});
                                if ((s64 < 0) || (s64 >= signed'({32'b0, nch}))) begin
                                    if (op_r == PY_SA_ITER_NEXT)
                                        set_res(pycore_make_control(PY_CTL_NONE), heap_ptr_r);
                                    else
                                        set_trap(PY_TRAP_MEM_FAULT);
                                end else begin
                                    eng_r <= ENG_CHAR;
                                    src_idx_r <= s64[31:0];
                                    src_sel_r <= SRC_A;
                                    dst_nchars_r <= 32'd1;
                                    state_r <= ST_STEP;
                                end
                            end
                        end
                        default: set_trap(PY_TRAP_TYPE);
                    endcase
                end

                ST_MEM_ISSUE: state_r <= ST_MEM_WAIT;

                ST_MEM_WAIT: begin
                    if (ack_i) begin
                        if (fault_i)
                            set_trap(PY_TRAP_MEM_FAULT);
                        else begin
                            if (mem_kind_r == MEM_RD) begin
                                src_word_r <= rdata_i;
                                src_word_addr_r <= mem_addr_r;
                                src_word_valid_r <= 1'b1;
                            end else if (mem_kind_r == MEM_WR_DST)
                                dst_word_dirty_r <= 1'b0;
                            else if (mem_kind_r == MEM_WR_HDR) begin
                                set_res(pycore_make_entry(PY_TAG_LONG_STR,
                                    pycore_stracc_pack_handle(
                                        dst_place_r, dst_nchars_r, dst_nbytes_r[23:0],
                                        dst_kind_r, hash_r, flags_r)),
                                    dst_end_r);
                            end
                            if (mem_kind_r != MEM_WR_HDR)
                                state_r <= ST_STEP;
                        end
                    end
                end

                ST_STEP: begin
                    unique case (eng_r)
                        ENG_COPY: step_copy();
                        ENG_CMP: step_cmp();
                        ENG_SEARCH: step_search();
                        ENG_CHAR: step_char();
                        default: set_trap(PY_TRAP_TYPE);
                    endcase
                end

                ST_DONE: state_r <= ST_IDLE;

                default: state_r <= ST_IDLE;
            endcase
        end
    end

    // ---- nested tasks (SV allows tasks in modules) ----------------------

    function automatic logic [PYCORE_ENTRY_WIDTH-1:0] cmd_entry(
        input logic [3:0] tag,
        input logic [127:0] val
    );
        cmd_entry = pycore_make_entry(tag, val);
    endfunction

    task automatic setup_copy(input logic [31:0] nout, input logic [2:0] kind);
        logic [31:0] nbytes, obj_bytes, place, end_addr;
        nbytes = nout * {29'b0, kind};
        if ((kind == 3'd1) && (nout <= 32'(PYCORE_SHORT_STR_MAX_BYTES))) begin
            dst_short_r <= 1'b1;
            dst_nchars_r <= nout;
            dst_kind_r <= kind;
            dst_nbytes_r <= nbytes;
            dst_place_r <= heap_ptr_r;
            dst_end_r <= heap_ptr_r;
            eng_r <= ENG_COPY;
            out_idx_r <= 32'd0;
            src_sel_r <= SRC_A;
            state_r <= ST_STEP;
        end else begin
            obj_bytes = 32'd16 + ((nbytes + 32'd15) & ~32'd15);
            place = pycore_heap_place(heap_ptr_r, obj_bytes);
            end_addr = place + obj_bytes;
            if (end_addr > HEAP_LIMIT)
                set_trap(PY_TRAP_MEM_FAULT);
            else begin
                dst_short_r <= 1'b0;
                dst_nchars_r <= nout;
                dst_kind_r <= kind;
                dst_nbytes_r <= nbytes;
                dst_place_r <= place;
                dst_end_r <= end_addr;
                dst_word_r <= '0;
                dst_word_addr_r <= place + 32'd16;
                dst_word_dirty_r <= 1'b0;
                eng_r <= ENG_COPY;
                out_idx_r <= 32'd0;
                src_sel_r <= SRC_A;
                state_r <= ST_STEP;
            end
        end
    endtask

    task automatic prep_search();
        logic [31:0] start_u, hay_n, nee_n;
        logic signed [63:0] s64;
        hay_n = view_nchars(a_tag_r, a_val_r);
        nee_n = view_nchars(b_tag_r, b_val_r);
        start_u = 32'd0;
        if (!c_is_none) begin
            if (!c_is_int) begin
                set_trap(PY_TRAP_TYPE);
                return;
            end
            s64 = pycore_stracc_int64(c_val_r);
            if (s64 < 0)
                s64 = s64 + signed'({32'b0, hay_n});
            if (s64 < 0)
                s64 = 0;
            start_u = s64[31:0];
        end
        search_start_r <= start_u;
        search_end_r <= hay_n;
        nlen_r <= nee_n;
        rfind_r <= (var_r == PY_SA_RFIND);
        count_r <= 32'd0;
        have_hay_r <= 1'b0;
        match_i_r <= 32'd0;
        if ((nee_n > 32'd0) && (view_kind(b_tag_r, b_val_r) > view_kind(a_tag_r, a_val_r)))
            search_done();
        else if (nee_n == 32'd0)
            search_empty(start_u, hay_n);
        else if (nee_n > hay_n)
            search_done();
        else begin
            unique case (var_r)
                PY_SA_STARTSWITH: pos_r <= start_u;
                PY_SA_ENDSWITH: pos_r <= hay_n - nee_n;
                PY_SA_RFIND: pos_r <= hay_n - nee_n;
                default: pos_r <= start_u;
            endcase
            eng_r <= ENG_SEARCH;
            state_r <= ST_STEP;
        end
    endtask

    task automatic search_done();
        unique case (var_r)
            PY_SA_FIND, PY_SA_RFIND:
                set_res(pycore_stracc_make_int(-32'sd1), heap_ptr_r);
            PY_SA_COUNT:
                set_res(pycore_make_entry(PY_TAG_INT, {96'b0, count_r}), heap_ptr_r);
            default:
                set_res(pycore_make_entry(PY_TAG_BOOL, 128'd0), heap_ptr_r);
        endcase
    endtask

    task automatic search_empty(input logic [31:0] start_u, input logic [31:0] hay_n);
        unique case (var_r)
            PY_SA_FIND:
                set_res(pycore_make_entry(PY_TAG_INT, {96'b0, start_u}), heap_ptr_r);
            PY_SA_RFIND:
                set_res(pycore_make_entry(PY_TAG_INT, {96'b0, hay_n}), heap_ptr_r);
            PY_SA_COUNT:
                set_res(pycore_make_entry(PY_TAG_INT, {96'b0, (hay_n - start_u + 32'd1)}),
                        heap_ptr_r);
            default:
                set_res(pycore_make_entry(PY_TAG_BOOL, 128'd1), heap_ptr_r);
        endcase
    endtask

    task automatic pick_src();
        if (op_r == PY_SA_CONCAT) begin
            if (out_idx_r < split_r) begin
                src_sel_r = SRC_A;
                src_idx_r = out_idx_r;
            end else begin
                src_sel_r = SRC_B;
                src_idx_r = out_idx_r - split_r;
            end
        end else if (op_r == PY_SA_REPEAT) begin
            src_sel_r = SRC_A;
            src_idx_r = (a_nchars_r == 32'd0) ? 32'd0
                      : (out_idx_r % a_nchars_r);
        end else if (op_r == PY_SA_SLICE) begin
            src_sel_r = SRC_A;
            // src_idx_r already start; add out_idx
            src_idx_r = src_idx_r; // set by caller via out + base stored in split? 
        end else if (op_r == PY_SA_PAD) begin
            if (out_idx_r < left_pad_r)
                src_sel_r = SRC_FILL;
            else if (out_idx_r < right_start_r) begin
                src_sel_r = SRC_A;
                src_idx_r = out_idx_r - left_pad_r;
            end else
                src_sel_r = SRC_FILL;
        end else
            src_sel_r = SRC_A;
    endtask

    // pick_src uses blocking assigns on *_r which is wrong inside always_ff NBA.
    // step_copy computes src combinationally instead.

    task automatic step_copy();
        logic [31:0] sidx, nch, saddr;
        logic [2:0]  skind;
        logic        sshort;
        logic [127:0] sval;
        src_e sel;
        logic [31:0] unit;
        logic [31:0] byte_addr, word_addr;
        logic [3:0]  boff;
        logic [31:0] next_hash;
        int unsigned bi;
        logic [127:0] next_word;
        logic [31:0] slice_base;

        slice_base = (op_r == PY_SA_SLICE) ? src_idx_r : 32'd0;
        // For slice, src_idx_r holds the start and must not be overwritten.
        // Compute fetch index separately.
        begin
            logic [31:0] fetch_idx;
            if (op_r == PY_SA_CONCAT) begin
                if (out_idx_r < split_r) begin
                    sel = SRC_A;
                    fetch_idx = out_idx_r;
                end else begin
                    sel = SRC_B;
                    fetch_idx = out_idx_r - split_r;
                end
            end else if (op_r == PY_SA_REPEAT) begin
                sel = SRC_A;
                fetch_idx = (a_nchars_r == 32'd0) ? 32'd0 : (out_idx_r % a_nchars_r);
            end else if (op_r == PY_SA_SLICE) begin
                sel = SRC_A;
                fetch_idx = src_idx_r + out_idx_r;
            end else if (op_r == PY_SA_PAD) begin
                if (out_idx_r < left_pad_r) begin
                    sel = SRC_FILL;
                    fetch_idx = 32'd0;
                end else if (out_idx_r < right_start_r) begin
                    sel = SRC_A;
                    fetch_idx = out_idx_r - left_pad_r;
                end else begin
                    sel = SRC_FILL;
                    fetch_idx = 32'd0;
                end
            end else begin
                sel = SRC_A;
                fetch_idx = out_idx_r;
            end

            if (out_idx_r >= dst_nchars_r) begin
                finish_copy();
            end else if (sel == SRC_FILL) begin
                consume_unit(fill_unit_r);
            end else begin
                if (sel == SRC_A) begin
                    sshort = a_short_r;
                    sval = a_val_r;
                    skind = a_kind_r;
                    saddr = a_addr_r;
                    nch = a_nchars_r;
                end else begin
                    sshort = b_short_r;
                    sval = b_val_r;
                    skind = b_kind_r;
                    saddr = b_addr_r;
                    nch = b_nchars_r;
                end
                sidx = fetch_idx;
                if (sshort) begin
                    unit = {24'b0, pycore_short_str_byte(sval, sidx)};
                    bytes_scanned_r <= bytes_scanned_r + 32'd1;
                    consume_unit(unit);
                end else begin
                    byte_addr = saddr + 32'd16 + (sidx * {29'b0, skind});
                    word_addr = {byte_addr[31:4], 4'b0};
                    if (!src_word_valid_r || (src_word_addr_r != word_addr))
                        issue_read(word_addr);
                    else begin
                        boff = byte_addr[3:0];
                        unit = pycore_stracc_unit_from_word(src_word_r, boff, skind);
                        bytes_scanned_r <= bytes_scanned_r + {29'b0, skind};
                        consume_unit(unit);
                    end
                end
            end
        end
    endtask

    task automatic consume_unit(input logic [31:0] unit);
        logic [31:0] byte_addr, word_addr, next_hash;
        logic [3:0]  boff;
        int unsigned bi;
        logic [127:0] next_word;
        logic [7:0]  ubyte;

        flags_r <= pycore_stracc_case_flags_step(flags_r, unit);
        next_hash = hash_r;
        for (bi = 0; bi < 4; bi++) begin
            if (bi < int'(dst_kind_r)) begin
                ubyte = unit[8*bi +: 8];
                next_hash = pycore_stracc_fnv_step(next_hash, ubyte);
            end
        end
        hash_r <= next_hash;

        if (dst_short_r) begin
            short_bytes_r[out_idx_r] <= unit[7:0];
            bytes_written_r <= bytes_written_r + 32'd1;
            out_idx_r <= out_idx_r + 32'd1;
        end else begin
            byte_addr = dst_place_r + 32'd16 + (out_idx_r * {29'b0, dst_kind_r});
            word_addr = {byte_addr[31:4], 4'b0};
            boff = byte_addr[3:0];
            if (dst_word_dirty_r && (dst_word_addr_r != word_addr))
                issue_write(dst_word_addr_r, dst_word_r, MEM_WR_DST);
            else begin
                next_word = (dst_word_dirty_r && (dst_word_addr_r == word_addr))
                          ? dst_word_r : 128'd0;
                next_word = pycore_stracc_insert_unit(next_word, boff, dst_kind_r, unit);
                dst_word_r <= next_word;
                dst_word_addr_r <= word_addr;
                dst_word_dirty_r <= 1'b1;
                bytes_written_r <= bytes_written_r + {29'b0, dst_kind_r};
                out_idx_r <= out_idx_r + 32'd1;
            end
        end
    endtask

    task automatic finish_copy();
        if (dst_short_r)
            set_res(pack_short_local(), heap_ptr_r);
        else if (dst_word_dirty_r)
            issue_write(dst_word_addr_r, dst_word_r, MEM_WR_DST);
        else
            issue_write(dst_place_r,
                pycore_stracc_pack_header(
                    dst_nchars_r, dst_nbytes_r[23:0], dst_kind_r, hash_r, flags_r),
                MEM_WR_HDR);
    endtask

    task automatic fetch_unit_ab(
        input src_e sel,
        input logic [31:0] idx,
        output logic got,
        output logic [31:0] unit
    );
        logic sshort;
        logic [127:0] sval;
        logic [2:0] skind;
        logic [31:0] saddr, byte_addr, word_addr;
        logic [3:0] boff;
        got = 1'b0;
        unit = 32'd0;
        if (sel == SRC_A) begin
            sshort = a_short_r;
            sval = a_val_r;
            skind = a_kind_r;
            saddr = a_addr_r;
        end else begin
            sshort = b_short_r;
            sval = b_val_r;
            skind = b_kind_r;
            saddr = b_addr_r;
        end
        if (sshort) begin
            unit = {24'b0, pycore_short_str_byte(sval, idx)};
            got = 1'b1;
            bytes_scanned_r <= bytes_scanned_r + 32'd1;
        end else begin
            byte_addr = saddr + 32'd16 + (idx * {29'b0, skind});
            word_addr = {byte_addr[31:4], 4'b0};
            if (!src_word_valid_r || (src_word_addr_r != word_addr))
                issue_read(word_addr);
            else begin
                boff = byte_addr[3:0];
                unit = pycore_stracc_unit_from_word(src_word_r, boff, skind);
                got = 1'b1;
                bytes_scanned_r <= bytes_scanned_r + {29'b0, skind};
            end
        end
    endtask

    task automatic step_cmp();
        logic got;
        logic [31:0] unit;
        logic [31:0] min_n;
        min_n = (a_nchars_r < b_nchars_r) ? a_nchars_r : b_nchars_r;
        if (cmp_idx_r >= min_n) begin
            if (a_nchars_r < b_nchars_r)
                set_res(pycore_stracc_make_int(-32'sd1), heap_ptr_r);
            else if (a_nchars_r > b_nchars_r)
                set_res(pycore_stracc_make_int(32'sd1), heap_ptr_r);
            else
                set_res(pycore_stracc_make_int(32'sd0), heap_ptr_r);
        end else if (!have_hay_r) begin
            fetch_unit_ab(SRC_A, cmp_idx_r, got, unit);
            if (got) begin
                hay_unit_r <= unit;
                have_hay_r <= 1'b1;
                src_word_valid_r <= src_word_valid_r;
            end
        end else begin
            fetch_unit_ab(SRC_B, cmp_idx_r, got, unit);
            if (got) begin
                if (hay_unit_r != unit) begin
                    if (hay_unit_r < unit)
                        set_res(pycore_stracc_make_int(-32'sd1), heap_ptr_r);
                    else
                        set_res(pycore_stracc_make_int(32'sd1), heap_ptr_r);
                end else begin
                    cmp_idx_r <= cmp_idx_r + 32'd1;
                    have_hay_r <= 1'b0;
                end
            end
        end
    endtask

    task automatic step_search();
        logic got;
        logic [31:0] unit;
        logic [31:0] hay_i;
        if ((var_r == PY_SA_STARTSWITH) || (var_r == PY_SA_ENDSWITH)) begin
            if (pos_r + nlen_r > search_end_r) begin
                set_res(pycore_make_entry(PY_TAG_BOOL, 128'd0), heap_ptr_r);
                return;
            end
        end         else if (rfind_r) begin
            if (pos_r < search_start_r) begin
                search_done();
                return;
            end
        end else if (pos_r + nlen_r > search_end_r) begin
            search_done();
            return;
        end

        hay_i = pos_r + match_i_r;
        if (!have_hay_r) begin
            fetch_unit_ab(SRC_A, hay_i, got, unit);
            if (got) begin
                hay_unit_r <= unit;
                have_hay_r <= 1'b1;
            end
        end else begin
            fetch_unit_ab(SRC_B, match_i_r, got, unit);
            if (got) begin
                if (hay_unit_r != unit) begin
                    have_hay_r <= 1'b0;
                    match_i_r <= 32'd0;
                    if ((var_r == PY_SA_STARTSWITH) || (var_r == PY_SA_ENDSWITH))
                        set_res(pycore_make_entry(PY_TAG_BOOL, 128'd0), heap_ptr_r);
                    else if (rfind_r)
                        pos_r <= pos_r - 32'd1;
                    else
                        pos_r <= pos_r + 32'd1;
                end else if (match_i_r + 32'd1 == nlen_r) begin
                    have_hay_r <= 1'b0;
                    match_i_r <= 32'd0;
                    unique case (var_r)
                        PY_SA_FIND:
                            set_res(pycore_make_entry(PY_TAG_INT, {96'b0, pos_r}),
                                    heap_ptr_r);
                        PY_SA_RFIND:
                            set_res(pycore_make_entry(PY_TAG_INT, {96'b0, pos_r}),
                                    heap_ptr_r);
                        PY_SA_CONTAINS, PY_SA_STARTSWITH, PY_SA_ENDSWITH:
                            set_res(pycore_make_entry(PY_TAG_BOOL, 128'd1), heap_ptr_r);
                        PY_SA_COUNT: begin
                            count_r <= count_r + 32'd1;
                            pos_r <= pos_r + nlen_r;
                        end
                        default: search_done();
                    endcase
                end else begin
                    have_hay_r <= 1'b0;
                    match_i_r <= match_i_r + 32'd1;
                end
            end
        end
    endtask

    task automatic step_char();
        logic got;
        logic [31:0] unit;
        logic [2:0] k;
        fetch_unit_ab(SRC_A, src_idx_r, got, unit);
        if (got) begin
            k = pycore_stracc_kind_of_unit(unit);
            fill_unit_r <= unit;
            left_pad_r <= 32'd0;
            right_start_r <= 32'd1;
            split_r <= 32'd1;
            src_idx_r <= 32'd0;
            out_idx_r <= 32'd0;
            hash_r <= PYCORE_STRACC_FNV_OFFSET;
            flags_r <= PYCORE_STRACC_FLAG_ALL_LOWER | PYCORE_STRACC_FLAG_ALL_UPPER;
            setup_copy(32'd1, k);
            // setup_copy sets ENG_COPY; inject the unit next step via FILL
            op_r <= PY_SA_PAD;
            fill_unit_r <= unit;
            left_pad_r <= 32'd1;
            right_start_r <= 32'd1;
        end
    endtask
endmodule
