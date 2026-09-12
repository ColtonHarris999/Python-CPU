`include "pycore_defs.svh"

// String Accelerator (planning/string_accelerator_plan.md P5c).
// Own dmem master. Active only while the core is frozen in S_STRACC.
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

    typedef enum logic [3:0] {
        ENG_NONE,
        ENG_COPY,
        ENG_CMP,
        ENG_SEARCH,
        ENG_HASH,
        ENG_CHAR,
        ENG_REPLACE,
        ENG_JOIN,
        ENG_TRIM,
        ENG_CLASSIFY,
        ENG_MAP,
        ENG_AFFIX,
        ENG_EXPAND,
        ENG_SPLIT
    } eng_e;

    typedef enum logic [2:0] {
        SRC_A,
        SRC_B,
        SRC_FILL,
        SRC_C,
        SRC_EL
    } src_e;

    localparam logic [3:0] JP_HDR           = 4'd0;
    localparam logic [3:0] JP_OBITEM        = 4'd1;
    localparam logic [3:0] JP_NEED_TAG      = 4'd2;
    localparam logic [3:0] JP_GOT_TAG       = 4'd3;
    localparam logic [3:0] JP_GOT_VAL       = 4'd4;
    localparam logic [3:0] JP_FILL_NEED_TAG = 4'd5;
    localparam logic [3:0] JP_FILL_GOT_TAG  = 4'd6;
    localparam logic [3:0] JP_FILL_GOT_VAL  = 4'd7;
    localparam logic [3:0] JP_FILL_COPY     = 4'd8;
    localparam logic [3:0] JP_STR_FILL      = 4'd9;

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

    logic [31:0] a_nchars_r, b_nchars_r, c_nchars_r;
    logic [2:0]  a_kind_r, b_kind_r, c_kind_r;
    logic [31:0] a_addr_r, b_addr_r, c_addr_r;
    logic        a_short_r, b_short_r, c_short_r;
    logic        replace_empty_r;
    logic        replace_fill_r;
    logic        replace_emit_new_r;
    logic        replace_copy_hay_r;
    logic [31:0] hay_pos_r;
    logic [31:0] new_idx_r;

    // JOIN / TRIM / MAP / CLASSIFY / AFFIX
    logic [3:0]  join_phase_r;
    logic [31:0] join_n_r;
    logic [31:0] join_i_r;
    logic [31:0] join_obj_r;
    logic [31:0] join_buf_r;
    logic        join_is_list_r;
    logic        join_is_str_r;
    logic [31:0] join_sum_r;
    logic [2:0]  join_kmax_r;
    logic [3:0]  join_el_tag_r;
    logic [127:0] join_el_val_r;
    logic [31:0] join_el_nchars_r;
    logic [2:0]  join_el_kind_r;
    logic [31:0] join_el_addr_r;
    logic        join_el_short_r;
    logic        join_fill_sep_r;
    logic [31:0] join_base_r;
    logic        trim_has_cs_r;
    logic        trim_in_cs_r;
    logic        trim_cs_done_r;
    logic [31:0] trim_lo_r;
    logic [31:0] trim_hi_r;
    logic        trim_left_done_r;
    logic        map_changed_r;
    logic        map_measuring_r;
    logic        map_expand_r;
    logic        map_prev_cased_r;
    logic [31:0] map_extra_r;
    logic [2:0]  map_kmax_r;
    logic        cls_ok_r;
    logic        cls_saw_cased_r;
    logic        cls_prev_cased_r;
    logic        cls_title_ok_r;
    logic [5:0]  a_flags_r;
    logic        copy_hold_r;
    logic [1:0]  hold_dest_r; // 0=part0, 1=part2, 2=list slot
    logic [PYCORE_ENTRY_WIDTH-1:0] part0_r, part2_r;

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
    wire c_is_str = (c_tag_r == PY_TAG_SHORT_STR) || (c_tag_r == PY_TAG_LONG_STR);
    wire b_is_list = pycore_is_list(b_tag_r, b_val_r);
    wire b_is_tuple = (b_tag_r == PY_TAG_TUPLE);

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
            copy_hold_r <= 1'b0;
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
                    c_nchars_r <= ((c_tag_r == PY_TAG_SHORT_STR) ||
                                   (c_tag_r == PY_TAG_LONG_STR))
                                ? view_nchars(c_tag_r, c_val_r) : 32'd0;
                    c_kind_r <= ((c_tag_r == PY_TAG_SHORT_STR) ||
                                 (c_tag_r == PY_TAG_LONG_STR))
                              ? view_kind(c_tag_r, c_val_r) : 3'd1;
                    c_addr_r <= pycore_stracc_addr(c_val_r);
                    c_short_r <= (c_tag_r == PY_TAG_SHORT_STR);
                    a_flags_r <= (a_tag_r == PY_TAG_LONG_STR)
                               ? pycore_stracc_flags(a_val_r) : 6'd0;
                    replace_empty_r <= 1'b0;
                    replace_fill_r <= 1'b0;
                    replace_emit_new_r <= 1'b0;
                    replace_copy_hay_r <= 1'b0;
                    hay_pos_r <= 32'd0;
                    new_idx_r <= 32'd0;
                    copy_hold_r <= 1'b0;
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
                        PY_SA_ORD: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(a_tag_r, a_val_r) != 32'd1)
                                set_trap(PY_TRAP_TYPE);
                            else if (a_tag_r == PY_TAG_SHORT_STR)
                                set_res(pycore_make_entry(PY_TAG_INT,
                                    {120'b0, pycore_short_str_byte(a_val_r, 0)}),
                                    heap_ptr_r);
                            else begin
                                eng_r <= ENG_CHAR;
                                src_idx_r <= 32'd0;
                                src_sel_r <= SRC_A;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_CHR: begin
                            if (!a_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else if ((a_val_r[127:32] != 96'b0) ||
                                     (a_val_r[31:0] > 32'h0010_FFFF))
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                unit = a_val_r[31:0];
                                kmax = pycore_stracc_kind_of_unit(unit);
                                fill_unit_r <= unit;
                                left_pad_r <= 32'd1;
                                right_start_r <= 32'd1;
                                split_r <= 32'd1;
                                op_r <= PY_SA_PAD;
                                setup_copy(32'd1, kmax);
                            end
                        end
                        PY_SA_REPLACE: begin
                            if (!a_is_str || !b_is_str || !c_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if ((view_nchars(b_tag_r, b_val_r) == 32'd0) &&
                                     (view_nchars(c_tag_r, c_val_r) == 32'd0))
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else if (view_nchars(b_tag_r, b_val_r) == 32'd0) begin
                                nch = view_nchars(a_tag_r, a_val_r);
                                nout = nch + (nch + 32'd1) *
                                       view_nchars(c_tag_r, c_val_r);
                                kmax = (view_kind(a_tag_r, a_val_r) >
                                        view_kind(c_tag_r, c_val_r))
                                     ? view_kind(a_tag_r, a_val_r)
                                     : view_kind(c_tag_r, c_val_r);
                                replace_empty_r <= 1'b1;
                                replace_fill_r <= 1'b1;
                                hay_pos_r <= 32'd0;
                                new_idx_r <= 32'd0;
                                setup_copy(nout, kmax);
                                eng_r <= ENG_REPLACE;
                            end else if ((view_nchars(b_tag_r, b_val_r) != 32'd0) &&
                                         (view_kind(b_tag_r, b_val_r) >
                                          view_kind(a_tag_r, a_val_r)))
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else begin
                                replace_empty_r <= 1'b0;
                                replace_fill_r <= 1'b0;
                                count_r <= 32'd0;
                                pos_r <= 32'd0;
                                match_i_r <= 32'd0;
                                have_hay_r <= 1'b0;
                                nlen_r <= view_nchars(b_tag_r, b_val_r);
                                search_start_r <= 32'd0;
                                search_end_r <= view_nchars(a_tag_r, a_val_r);
                                eng_r <= ENG_REPLACE;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_JOIN: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (b_is_tuple) begin
                                join_is_list_r <= 1'b0;
                                join_is_str_r <= 1'b0;
                                join_n_r <= pycore_tuple_size(b_val_r)[31:0];
                                join_buf_r <= b_val_r[31:0];
                                join_obj_r <= b_val_r[31:0];
                                join_i_r <= 32'd0;
                                join_sum_r <= 32'd0;
                                join_kmax_r <= view_kind(a_tag_r, a_val_r);
                                if (pycore_tuple_size(b_val_r)[31:0] == 32'd0)
                                    set_res(pycore_make_short_str_entry(4'd0, 120'd0),
                                            heap_ptr_r);
                                else begin
                                    join_phase_r <= JP_NEED_TAG;
                                    eng_r <= ENG_JOIN;
                                    state_r <= ST_STEP;
                                end
                            end else if (b_is_list) begin
                                join_is_list_r <= 1'b1;
                                join_is_str_r <= 1'b0;
                                join_obj_r <= pycore_mut_addr(b_val_r)[31:0];
                                join_i_r <= 32'd0;
                                join_sum_r <= 32'd0;
                                join_kmax_r <= view_kind(a_tag_r, a_val_r);
                                join_phase_r <= JP_HDR;
                                eng_r <= ENG_JOIN;
                                issue_read(pycore_mut_addr(b_val_r)[31:0]);
                            end else if (b_is_str) begin
                                nch = view_nchars(b_tag_r, b_val_r);
                                join_is_list_r <= 1'b0;
                                join_is_str_r <= 1'b1;
                                join_n_r <= nch;
                                join_i_r <= 32'd0;
                                join_sum_r <= nch;
                                kmax = (view_kind(a_tag_r, a_val_r) >
                                        view_kind(b_tag_r, b_val_r))
                                     ? view_kind(a_tag_r, a_val_r)
                                     : view_kind(b_tag_r, b_val_r);
                                join_kmax_r <= kmax;
                                if (nch == 32'd0)
                                    set_res(pycore_make_short_str_entry(4'd0, 120'd0),
                                            heap_ptr_r);
                                else if (nch == 32'd1)
                                    set_res(cmd_entry(b_tag_r, b_val_r), heap_ptr_r);
                                else if (view_nchars(a_tag_r, a_val_r) == 32'd0)
                                    set_res(cmd_entry(b_tag_r, b_val_r), heap_ptr_r);
                                else begin
                                    nout = nch + (nch - 32'd1) *
                                           view_nchars(a_tag_r, a_val_r);
                                    join_fill_sep_r <= 1'b0;
                                    join_base_r <= 32'd0;
                                    join_phase_r <= JP_STR_FILL;
                                    setup_copy(nout, kmax);
                                    eng_r <= ENG_JOIN;
                                end
                            end else
                                set_trap(PY_TRAP_TYPE);
                        end
                        PY_SA_TRIM: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (!b_is_none && !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(a_tag_r, a_val_r) == 32'd0)
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else begin
                                trim_has_cs_r <= b_is_str;
                                trim_left_done_r <= (var_r == PY_SA_TRIM_RIGHT);
                                pos_r <= 32'd0;
                                match_i_r <= 32'd0;
                                have_hay_r <= 1'b0;
                                trim_lo_r <= 32'd0;
                                trim_hi_r <= view_nchars(a_tag_r, a_val_r);
                                nlen_r <= b_is_str ? view_nchars(b_tag_r, b_val_r)
                                                   : 32'd0;
                                eng_r <= ENG_TRIM;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_CLASSIFY: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(a_tag_r, a_val_r) == 32'd0) begin
                                if ((var_r == PY_SA_IS_ASCII) ||
                                    (var_r == PY_SA_IS_PRINTABLE))
                                    set_res(pycore_make_entry(PY_TAG_BOOL, 128'd1),
                                            heap_ptr_r);
                                else
                                    set_res(pycore_make_entry(PY_TAG_BOOL, 128'd0),
                                            heap_ptr_r);
                            end else if ((view_kind(a_tag_r, a_val_r) > 3'd1) &&
                                         (var_r == PY_SA_IS_ASCII))
                                set_res(pycore_make_entry(PY_TAG_BOOL, 128'd0),
                                        heap_ptr_r);
                            else if (view_kind(a_tag_r, a_val_r) > 3'd1)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                pos_r <= 32'd0;
                                cls_ok_r <= 1'b1;
                                cls_saw_cased_r <= 1'b0;
                                cls_prev_cased_r <= 1'b0;
                                cls_title_ok_r <= 1'b1;
                                eng_r <= ENG_CLASSIFY;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_MAP: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_kind(a_tag_r, a_val_r) > 3'd1)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(a_tag_r, a_val_r) == 32'd0)
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else if ((a_tag_r == PY_TAG_LONG_STR) &&
                                     (var_r == PY_SA_MAP_UPPER) &&
                                     ((pycore_stracc_flags(a_val_r) &
                                       PYCORE_STRACC_FLAG_ALL_UPPER) != 6'd0))
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else if ((a_tag_r == PY_TAG_LONG_STR) &&
                                     (var_r == PY_SA_MAP_LOWER) &&
                                     ((pycore_stracc_flags(a_val_r) &
                                       PYCORE_STRACC_FLAG_ALL_LOWER) != 6'd0))
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else begin
                                pos_r <= 32'd0;
                                map_changed_r <= 1'b0;
                                map_measuring_r <= 1'b1;
                                map_expand_r <= 1'b0;
                                map_prev_cased_r <= 1'b0;
                                map_extra_r <= 32'd0;
                                map_kmax_r <= view_kind(a_tag_r, a_val_r);
                                have_hay_r <= 1'b0;
                                eng_r <= ENG_MAP;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_AFFIX: begin
                            if (!a_is_str || !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (view_nchars(b_tag_r, b_val_r) == 32'd0)
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else if ((view_nchars(b_tag_r, b_val_r) >
                                      view_nchars(a_tag_r, a_val_r)) ||
                                     (view_kind(b_tag_r, b_val_r) >
                                      view_kind(a_tag_r, a_val_r)))
                                set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                            else begin
                                pos_r <= 32'd0;
                                match_i_r <= 32'd0;
                                have_hay_r <= 1'b0;
                                nlen_r <= view_nchars(b_tag_r, b_val_r);
                                if (var_r == PY_SA_AFFIX_SUFFIX)
                                    pos_r <= view_nchars(a_tag_r, a_val_r) -
                                             view_nchars(b_tag_r, b_val_r);
                                eng_r <= ENG_AFFIX;
                                state_r <= ST_STEP;
                            end
                        end
                        PY_SA_ZFILL: begin
                            if (!a_is_str || !b_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = pycore_stracc_int64(b_val_r);
                                nch = view_nchars(a_tag_r, a_val_r);
                                if (s64 <= signed'({32'b0, nch}))
                                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                                else if (nch == 32'd0) begin
                                    pad = s64[31:0];
                                    fill_unit_r <= 32'h30;
                                    left_pad_r <= pad;
                                    right_start_r <= pad;
                                    split_r <= pad;
                                    setup_copy(s64[31:0], 3'd1);
                                    op_r <= PY_SA_PAD;
                                end else begin
                                    pad = s64[31:0] - nch;
                                    fill_unit_r <= 32'h30;
                                    split_r <= pad;
                                    dst_nchars_r <= s64[31:0];
                                    map_measuring_r <= 1'b1;
                                    map_expand_r <= 1'b0;
                                    eng_r <= ENG_MAP;
                                    op_r <= PY_SA_ZFILL;
                                    state_r <= ST_STEP;
                                end
                            end
                        end
                        PY_SA_EXPANDTABS: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if (!b_is_none && !b_is_int)
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = b_is_none ? 64'sd8 : pycore_stracc_int64(b_val_r);
                                if (view_nchars(a_tag_r, a_val_r) == 32'd0)
                                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                                else begin
                                    // CPython: tabsize < 1 deletes tabs (no divide).
                                    split_r <= (s64 <= 0) ? 32'd0 : s64[31:0];
                                    pos_r <= 32'd0;
                                    count_r <= 32'd0;
                                    cmp_idx_r <= 32'd0;
                                    map_changed_r <= 1'b0;
                                    map_measuring_r <= 1'b1;
                                    new_idx_r <= 32'd0;
                                    eng_r <= ENG_EXPAND;
                                    state_r <= ST_STEP;
                                end
                            end
                        end
                        PY_SA_SPLIT: begin
                            if (!a_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if ((var_r == PY_SA_SPLIT_PARTITION) ||
                                     (var_r == PY_SA_SPLIT_RPARTITION)) begin
                                if (!b_is_str)
                                    set_trap(PY_TRAP_TYPE);
                                else if (view_nchars(b_tag_r, b_val_r) == 32'd0)
                                    set_trap(PY_TRAP_TYPE);
                                else begin
                                    nch = view_nchars(a_tag_r, a_val_r);
                                    nout = view_nchars(b_tag_r, b_val_r);
                                    rfind_r <= (var_r == PY_SA_SPLIT_RPARTITION);
                                    nlen_r <= nout;
                                    pos_r <= ((var_r == PY_SA_SPLIT_RPARTITION) &&
                                              (nch >= nout))
                                           ? (nch - nout) : 32'd0;
                                    match_i_r <= 32'd0;
                                    have_hay_r <= 1'b0;
                                    search_end_r <= nch;
                                    map_changed_r <= 1'b0;
                                    join_phase_r <= 4'd0;
                                    eng_r <= ENG_SPLIT;
                                    state_r <= ST_STEP;
                                end
                            end else if ((var_r != PY_SA_SPLIT_LINES) &&
                                         !b_is_none && !b_is_str)
                                set_trap(PY_TRAP_TYPE);
                            else if ((var_r == PY_SA_SPLIT_LINES) &&
                                     !b_is_none && !b_is_int &&
                                     (b_tag_r != PY_TAG_BOOL))
                                set_trap(PY_TRAP_TYPE);
                            else if (b_is_str &&
                                     (view_nchars(b_tag_r, b_val_r) == 32'd0) &&
                                     (var_r != PY_SA_SPLIT_LINES))
                                set_trap(PY_TRAP_TYPE);
                            else begin
                                s64 = 64'sh7FFF_FFFF;
                                if (c_is_int)
                                    s64 = pycore_stracc_int64(c_val_r);
                                if (s64 < 0)
                                    s64 = 64'sh7FFF_FFFF;
                                count_r <= s64[31:0];
                                trim_has_cs_r <= b_is_str && (var_r != PY_SA_SPLIT_LINES);
                                map_expand_r <= (var_r == PY_SA_SPLIT_LINES) &&
                                    (((b_tag_r == PY_TAG_BOOL) && b_val_r[0]) ||
                                     (b_is_int && (b_val_r != 128'd0)));
                                pos_r <= 32'd0;
                                join_n_r <= 32'd0;
                                join_i_r <= 32'd0;
                                join_sum_r <= 32'd0;
                                split_r <= 32'd0;
                                left_pad_r <= 32'd0;
                                right_start_r <= 32'd0;
                                map_measuring_r <= 1'b1;
                                have_hay_r <= 1'b0;
                                match_i_r <= 32'd0;
                                trim_in_cs_r <= 1'b0;
                                replace_copy_hay_r <= 1'b0;
                                join_fill_sep_r <= 1'b0;
                                nlen_r <= (b_is_str && (var_r != PY_SA_SPLIT_LINES))
                                        ? view_nchars(b_tag_r, b_val_r) : 32'd0;
                                rfind_r <= (var_r == PY_SA_SPLIT_REV);
                                join_phase_r <= 4'd0;
                                eng_r <= ENG_SPLIT;
                                state_r <= ST_STEP;
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
                                if (copy_hold_r) begin
                                    hold_long_done(pycore_make_entry(PY_TAG_LONG_STR,
                                        pycore_stracc_pack_handle(
                                            dst_place_r, dst_nchars_r, dst_nbytes_r[23:0],
                                            dst_kind_r, hash_r, flags_r)),
                                        hold_dest_r);
                                    heap_ptr_r <= dst_end_r;
                                    copy_hold_r <= 1'b0;
                                    state_r <= ST_STEP;
                                end else begin
                                    set_res(pycore_make_entry(PY_TAG_LONG_STR,
                                        pycore_stracc_pack_handle(
                                            dst_place_r, dst_nchars_r, dst_nbytes_r[23:0],
                                            dst_kind_r, hash_r, flags_r)),
                                        dst_end_r);
                                end
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
                        ENG_CHAR: begin
                            if (op_r == PY_SA_ORD)
                                step_ord();
                            else
                                step_char();
                        end
                        ENG_REPLACE: step_replace();
                        ENG_JOIN: step_join();
                        ENG_TRIM: step_trim();
                        ENG_CLASSIFY: step_classify();
                        ENG_MAP: begin
                            if (op_r == PY_SA_ZFILL)
                                step_zfill();
                            else
                                step_map();
                        end
                        ENG_AFFIX: step_affix();
                        ENG_EXPAND: step_expandtabs();
                        ENG_SPLIT: step_split();
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
            hash_r <= PYCORE_STRACC_FNV_OFFSET;
            flags_r <= PYCORE_STRACC_FLAG_ALL_LOWER | PYCORE_STRACC_FLAG_ALL_UPPER;
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
                hash_r <= PYCORE_STRACC_FNV_OFFSET;
                flags_r <= PYCORE_STRACC_FLAG_ALL_LOWER | PYCORE_STRACC_FLAG_ALL_UPPER;
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
            end else if (op_r == PY_SA_ZFILL) begin
                if (map_expand_r) begin
                    if (out_idx_r == 32'd0) begin
                        sel = SRC_A;
                        fetch_idx = 32'd0;
                    end else if (out_idx_r <= split_r) begin
                        sel = SRC_FILL;
                        fetch_idx = 32'd0;
                    end else begin
                        sel = SRC_A;
                        fetch_idx = out_idx_r - split_r;
                    end
                end else if (out_idx_r < split_r) begin
                    sel = SRC_FILL;
                    fetch_idx = 32'd0;
                end else begin
                    sel = SRC_A;
                    fetch_idx = out_idx_r - split_r;
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
        if (dst_short_r) begin
            if (copy_hold_r) begin
                hold_long_done(pack_short_local(), hold_dest_r);
                copy_hold_r <= 1'b0;
            end else
                set_res(pack_short_local(), heap_ptr_r);
        end else if (dst_word_dirty_r)
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
        end else if (sel == SRC_C) begin
            sshort = c_short_r;
            sval = c_val_r;
            skind = c_kind_r;
            saddr = c_addr_r;
        end else if (sel == SRC_EL) begin
            sshort = join_el_short_r;
            sval = join_el_val_r;
            skind = join_el_kind_r;
            saddr = join_el_addr_r;
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

    task automatic step_ord();
        logic got;
        logic [31:0] unit;
        fetch_unit_ab(SRC_A, 32'd0, got, unit);
        if (got)
            set_res(pycore_make_entry(PY_TAG_INT, {96'b0, unit}), heap_ptr_r);
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

    task automatic finish_replace_measure();
        logic [31:0] nout;
        logic [2:0] kmax;
        if (count_r == 32'd0)
            set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
        else begin
            nout = a_nchars_r + (count_r * c_nchars_r) - (count_r * b_nchars_r);
            kmax = (a_kind_r > c_kind_r) ? a_kind_r : c_kind_r;
            replace_fill_r <= 1'b1;
            replace_emit_new_r <= 1'b0;
            hay_pos_r <= 32'd0;
            new_idx_r <= 32'd0;
            match_i_r <= 32'd0;
            have_hay_r <= 1'b0;
            setup_copy(nout, kmax);
            eng_r <= ENG_REPLACE;
        end
    endtask

    task automatic step_replace();
        logic got;
        logic [31:0] unit;
        logic [31:0] period, group, off;
        if (replace_fill_r && replace_empty_r) begin
            if (out_idx_r >= dst_nchars_r)
                finish_copy();
            else begin
                period = c_nchars_r + 32'd1;
                group = (period == 32'd0) ? 32'd0 : (out_idx_r / period);
                off = (period == 32'd0) ? 32'd0 : (out_idx_r % period);
                if (off < c_nchars_r)
                    fetch_unit_ab(SRC_C, off, got, unit);
                else
                    fetch_unit_ab(SRC_A, group, got, unit);
                if (got)
                    consume_unit(unit);
            end
        end else if (replace_fill_r) begin
            if (out_idx_r >= dst_nchars_r)
                finish_copy();
            else if (replace_emit_new_r) begin
                if (new_idx_r >= c_nchars_r) begin
                    replace_emit_new_r <= 1'b0;
                    hay_pos_r <= hay_pos_r + b_nchars_r;
                    match_i_r <= 32'd0;
                    have_hay_r <= 1'b0;
                    new_idx_r <= 32'd0;
                end else begin
                    fetch_unit_ab(SRC_C, new_idx_r, got, unit);
                    if (got) begin
                        consume_unit(unit);
                        new_idx_r <= new_idx_r + 32'd1;
                    end
                end
            end             else if (replace_copy_hay_r) begin
                fetch_unit_ab(SRC_A, hay_pos_r, got, unit);
                if (got) begin
                    consume_unit(unit);
                    hay_pos_r <= hay_pos_r + 32'd1;
                    replace_copy_hay_r <= 1'b0;
                    have_hay_r <= 1'b0;
                    match_i_r <= 32'd0;
                end
            end else if (hay_pos_r >= a_nchars_r)
                finish_copy();
            else if (hay_pos_r + b_nchars_r > a_nchars_r) begin
                fetch_unit_ab(SRC_A, hay_pos_r, got, unit);
                if (got) begin
                    consume_unit(unit);
                    hay_pos_r <= hay_pos_r + 32'd1;
                end
            end             else if (!have_hay_r) begin
                fetch_unit_ab(SRC_A, hay_pos_r + match_i_r, got, unit);
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
                        if (match_i_r == 32'd0) begin
                            consume_unit(hay_unit_r);
                            hay_pos_r <= hay_pos_r + 32'd1;
                        end else
                            replace_copy_hay_r <= 1'b1;
                    end else if (match_i_r + 32'd1 == b_nchars_r) begin
                        have_hay_r <= 1'b0;
                        match_i_r <= 32'd0;
                        if (c_nchars_r == 32'd0) begin
                            hay_pos_r <= hay_pos_r + b_nchars_r;
                        end else begin
                            replace_emit_new_r <= 1'b1;
                            new_idx_r <= 32'd0;
                        end
                    end else begin
                        have_hay_r <= 1'b0;
                        match_i_r <= match_i_r + 32'd1;
                    end
                end
            end
        end else begin
            // Measure: non-overlapping COUNT of B in A.
            if (pos_r + nlen_r > search_end_r)
                finish_replace_measure();
            else if (!have_hay_r) begin
                fetch_unit_ab(SRC_A, pos_r + match_i_r, got, unit);
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
                        pos_r <= pos_r + 32'd1;
                    end else if (match_i_r + 32'd1 == nlen_r) begin
                        have_hay_r <= 1'b0;
                        match_i_r <= 32'd0;
                        count_r <= count_r + 32'd1;
                        pos_r <= pos_r + nlen_r;
                    end else begin
                        have_hay_r <= 1'b0;
                        match_i_r <= match_i_r + 32'd1;
                    end
                end
            end
        end
    endtask

    function automatic logic dest_can_take();
        logic [31:0] byte_addr, word_addr;
        if (dst_short_r)
            dest_can_take = 1'b1;
        else begin
            byte_addr = dst_place_r + 32'd16 + (out_idx_r * {29'b0, dst_kind_r});
            word_addr = {byte_addr[31:4], 4'b0};
            dest_can_take = !(dst_word_dirty_r && (dst_word_addr_r != word_addr));
        end
    endfunction

    function automatic logic [31:0] map_second_unit();
        unique case (var_r)
            PY_SA_MAP_UPPER, PY_SA_MAP_SWAPCASE: map_second_unit = 32'h53;
            default: map_second_unit = 32'h73;
        endcase
    endfunction

    task automatic map_apply(
        input logic [31:0] u,
        input logic [31:0] idx,
        input logic prev_cased,
        output logic [31:0] mu,
        output logic expands,
        output logic next_cased
    );
        logic cased;
        cased = pycore_latin1_is_cased(u);
        expands = 1'b0;
        mu = u;
        next_cased = cased;
        unique case (var_r)
            PY_SA_MAP_UPPER: begin
                mu = pycore_latin1_toupper(u);
                expands = pycore_map_expands_ss(u);
                next_cased = prev_cased;
            end
            PY_SA_MAP_LOWER: begin
                mu = pycore_latin1_tolower(u);
                next_cased = prev_cased;
            end
            PY_SA_MAP_SWAPCASE: begin
                if (pycore_latin1_is_upper(u))
                    mu = pycore_latin1_tolower(u);
                else if (pycore_latin1_is_lower(u)) begin
                    mu = pycore_latin1_toupper(u);
                    expands = pycore_map_expands_ss(u);
                end
                next_cased = prev_cased;
            end
            PY_SA_MAP_CAPITALIZE: begin
                if (idx == 32'd0) begin
                    mu = pycore_latin1_toupper(u);
                    expands = pycore_map_expands_ss(u);
                end else
                    mu = pycore_latin1_tolower(u);
                next_cased = prev_cased;
            end
            PY_SA_MAP_TITLE: begin
                if (cased && !prev_cased) begin
                    mu = pycore_latin1_toupper(u);
                    expands = pycore_map_expands_ss(u);
                end else if (cased && prev_cased)
                    mu = pycore_latin1_tolower(u);
                else
                    mu = u;
                next_cased = cased;
            end
            PY_SA_MAP_CASEFOLD: begin
                mu = pycore_latin1_tocasefold(u);
                expands = pycore_map_expands_ss(u);
                next_cased = prev_cased;
            end
            default: begin
                mu = u;
                next_cased = prev_cased;
            end
        endcase
    endtask

    task automatic charset_has(
        input logic [31:0] unit,
        output logic done,
        output logic hit
    );
        logic got;
        logic [31:0] cu;
        done = 1'b0;
        hit = 1'b0;
        if (!trim_has_cs_r) begin
            done = 1'b1;
            hit = pycore_is_unicode_space(unit);
        end else if (nlen_r == 32'd0) begin
            done = 1'b1;
            hit = 1'b0;
        end else begin
            fetch_unit_ab(SRC_B, match_i_r, got, cu);
            if (got) begin
                if (cu == unit) begin
                    done = 1'b1;
                    hit = 1'b1;
                    match_i_r <= 32'd0;
                end else if (match_i_r + 32'd1 >= nlen_r) begin
                    done = 1'b1;
                    hit = 1'b0;
                    match_i_r <= 32'd0;
                end else
                    match_i_r <= match_i_r + 32'd1;
            end
        end
    endtask

    task automatic join_latch_el(input logic [3:0] tag, input logic [127:0] val);
        join_el_tag_r <= tag;
        join_el_val_r <= val;
        join_el_nchars_r <= view_nchars(tag, val);
        join_el_kind_r <= view_kind(tag, val);
        join_el_addr_r <= pycore_stracc_addr(val);
        join_el_short_r <= (tag == PY_TAG_SHORT_STR);
    endtask

    task automatic step_join();
        logic [31:0] n, nout, taddr, vaddr, fetch_idx, el_len, period, group, off;
        logic [2:0] kmax;
        logic [3:0] etag;
        logic got;
        logic [31:0] unit;
        n = join_n_r;
        unique case (join_phase_r)
            JP_HDR: begin
                n = pycore_list_length(src_word_r)[31:0];
                join_n_r <= n;
                if (n == 32'd0)
                    set_res(pycore_make_short_str_entry(4'd0, 120'd0), heap_ptr_r);
                else begin
                    join_phase_r <= JP_OBITEM;
                    issue_read(pycore_list_obitem_addr(join_obj_r));
                end
            end
            JP_OBITEM: begin
                join_buf_r <= pycore_list_obitem(src_word_r)[31:0];
                join_i_r <= 32'd0;
                join_sum_r <= 32'd0;
                join_kmax_r <= a_kind_r;
                join_phase_r <= JP_NEED_TAG;
            end
            JP_NEED_TAG: begin
                if (join_is_list_r)
                    taddr = pycore_list_tag_addr(join_buf_r, join_i_r);
                else
                    taddr = pycore_tuple_tag_addr(join_buf_r, join_i_r);
                join_phase_r <= JP_GOT_TAG;
                issue_read(taddr);
            end
            JP_GOT_TAG: begin
                join_el_tag_r <= src_word_r[3:0];
                if (join_is_list_r)
                    vaddr = pycore_list_val_addr(join_buf_r, join_i_r);
                else
                    vaddr = pycore_tuple_val_addr(join_buf_r, join_i_r);
                join_phase_r <= JP_GOT_VAL;
                issue_read(vaddr);
            end
            JP_GOT_VAL: begin
                etag = join_el_tag_r;
                join_latch_el(etag, src_word_r);
                if ((etag != PY_TAG_SHORT_STR) && (etag != PY_TAG_LONG_STR))
                    set_trap(PY_TRAP_TYPE);
                else if ((join_n_r == 32'd1) && (join_i_r == 32'd0))
                    set_res(cmd_entry(etag, src_word_r), heap_ptr_r);
                else begin
                    join_sum_r <= join_sum_r + view_nchars(etag, src_word_r);
                    kmax = (join_kmax_r > view_kind(etag, src_word_r))
                         ? join_kmax_r : view_kind(etag, src_word_r);
                    join_kmax_r <= kmax;
                    if (join_i_r + 32'd1 == join_n_r) begin
                        nout = join_sum_r + view_nchars(etag, src_word_r)
                             + (join_n_r - 32'd1) * a_nchars_r;
                        join_i_r <= 32'd0;
                        join_fill_sep_r <= 1'b0;
                        join_base_r <= 32'd0;
                        join_phase_r <= JP_FILL_NEED_TAG;
                        setup_copy(nout, kmax);
                        eng_r <= ENG_JOIN;
                    end else begin
                        join_i_r <= join_i_r + 32'd1;
                        join_phase_r <= JP_NEED_TAG;
                    end
                end
            end
            JP_FILL_NEED_TAG: begin
                if (join_is_list_r)
                    taddr = pycore_list_tag_addr(join_buf_r, join_i_r);
                else
                    taddr = pycore_tuple_tag_addr(join_buf_r, join_i_r);
                join_phase_r <= JP_FILL_GOT_TAG;
                issue_read(taddr);
            end
            JP_FILL_GOT_TAG: begin
                join_el_tag_r <= src_word_r[3:0];
                if (join_is_list_r)
                    vaddr = pycore_list_val_addr(join_buf_r, join_i_r);
                else
                    vaddr = pycore_tuple_val_addr(join_buf_r, join_i_r);
                join_phase_r <= JP_FILL_GOT_VAL;
                issue_read(vaddr);
            end
            JP_FILL_GOT_VAL: begin
                join_latch_el(join_el_tag_r, src_word_r);
                join_fill_sep_r <= 1'b0;
                join_base_r <= out_idx_r;
                join_phase_r <= JP_FILL_COPY;
            end
            JP_FILL_COPY: begin
                if (out_idx_r >= dst_nchars_r)
                    finish_copy();
                else begin
                    el_len = join_fill_sep_r ? a_nchars_r : join_el_nchars_r;
                    fetch_idx = out_idx_r - join_base_r;
                    if (fetch_idx >= el_len) begin
                        if (join_fill_sep_r) begin
                            join_fill_sep_r <= 1'b0;
                            join_i_r <= join_i_r + 32'd1;
                            join_base_r <= out_idx_r;
                            join_phase_r <= JP_FILL_NEED_TAG;
                        end else if (join_i_r + 32'd1 == join_n_r)
                            finish_copy();
                        else begin
                            join_fill_sep_r <= 1'b1;
                            join_base_r <= out_idx_r;
                        end
                    end else begin
                        if (join_fill_sep_r)
                            fetch_unit_ab(SRC_A, fetch_idx, got, unit);
                        else
                            fetch_unit_ab(SRC_EL, fetch_idx, got, unit);
                        if (got)
                            consume_unit(unit);
                    end
                end
            end
            JP_STR_FILL: begin
                if (out_idx_r >= dst_nchars_r)
                    finish_copy();
                else begin
                    if (a_nchars_r == 32'd0)
                        fetch_unit_ab(SRC_B, out_idx_r, got, unit);
                    else begin
                        period = 32'd1 + a_nchars_r;
                        group = out_idx_r / period;
                        off = out_idx_r % period;
                        if (off == 32'd0)
                            fetch_unit_ab(SRC_B, group, got, unit);
                        else
                            fetch_unit_ab(SRC_A, off - 32'd1, got, unit);
                    end
                    if (got)
                        consume_unit(unit);
                end
            end
            default: set_trap(PY_TRAP_TYPE);
        endcase
    endtask

    task automatic finish_trim_range(input logic [31:0] lo, input logic [31:0] hi);
        logic [31:0] nout;
        if ((lo == 32'd0) && (hi == a_nchars_r))
            set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
        else if (lo >= hi)
            set_res(pycore_make_short_str_entry(4'd0, 120'd0), heap_ptr_r);
        else begin
            nout = hi - lo;
            src_idx_r <= lo;
            op_r <= PY_SA_SLICE;
            setup_copy(nout, a_kind_r);
        end
    endtask

    task automatic step_trim();
        logic got, done, hit;
        logic [31:0] unit;
        if (!trim_left_done_r) begin
            if (pos_r >= a_nchars_r)
                finish_trim_range(a_nchars_r, a_nchars_r);
            else begin
                fetch_unit_ab(SRC_A, pos_r, got, unit);
                if (got) begin
                    charset_has(unit, done, hit);
                    if (done) begin
                        if (hit)
                            pos_r <= pos_r + 32'd1;
                        else if (var_r == PY_SA_TRIM_LEFT)
                            finish_trim_range(pos_r, a_nchars_r);
                        else begin
                            trim_lo_r <= pos_r;
                            trim_left_done_r <= 1'b1;
                            match_i_r <= 32'd0;
                        end
                    end
                end
            end
        end else if (trim_hi_r <= trim_lo_r)
            finish_trim_range(trim_lo_r, trim_hi_r);
        else begin
            fetch_unit_ab(SRC_A, trim_hi_r - 32'd1, got, unit);
            if (got) begin
                charset_has(unit, done, hit);
                if (done) begin
                    if (hit)
                        trim_hi_r <= trim_hi_r - 32'd1;
                    else
                        finish_trim_range(trim_lo_r, trim_hi_r);
                end
            end
        end
    endtask

    task automatic step_classify();
        logic got, pred, cased;
        logic [31:0] unit;
        if (pos_r >= a_nchars_r) begin
            unique case (var_r)
                PY_SA_IS_LOWER, PY_SA_IS_UPPER:
                    set_res(pycore_make_entry(PY_TAG_BOOL,
                        {127'b0, (cls_ok_r && cls_saw_cased_r)}), heap_ptr_r);
                PY_SA_IS_TITLE:
                    set_res(pycore_make_entry(PY_TAG_BOOL,
                        {127'b0, (cls_title_ok_r && cls_saw_cased_r)}),
                        heap_ptr_r);
                default:
                    set_res(pycore_make_entry(PY_TAG_BOOL, {127'b0, cls_ok_r}),
                            heap_ptr_r);
            endcase
        end else begin
            fetch_unit_ab(SRC_A, pos_r, got, unit);
            if (got) begin
                cased = pycore_latin1_is_cased(unit);
                pred = 1'b1;
                unique case (var_r)
                    PY_SA_IS_ALNUM: pred = pycore_latin1_is_alnum(unit);
                    PY_SA_IS_ALPHA: pred = pycore_latin1_is_alpha(unit);
                    PY_SA_IS_ASCII: pred = (unit <= 32'h7F);
                    PY_SA_IS_DIGIT: pred = pycore_latin1_is_digit(unit);
                    PY_SA_IS_SPACE: pred = pycore_is_unicode_space(unit);
                    PY_SA_IS_PRINTABLE: pred = pycore_latin1_is_printable(unit);
                    PY_SA_IS_DECIMAL: pred = pycore_latin1_is_decimal(unit);
                    PY_SA_IS_NUMERIC: pred = pycore_latin1_is_numeric(unit);
                    PY_SA_IS_LOWER: begin
                        if (pycore_latin1_is_upper(unit))
                            pred = 1'b0;
                        if (pycore_latin1_is_lower(unit))
                            cls_saw_cased_r <= 1'b1;
                    end
                    PY_SA_IS_UPPER: begin
                        if (pycore_latin1_is_lower(unit))
                            pred = 1'b0;
                        if (pycore_latin1_is_upper(unit))
                            cls_saw_cased_r <= 1'b1;
                    end
                    PY_SA_IS_TITLE: begin
                        if (pycore_latin1_is_upper(unit)) begin
                            if (cls_prev_cased_r)
                                cls_title_ok_r <= 1'b0;
                            cls_saw_cased_r <= 1'b1;
                            cls_prev_cased_r <= 1'b1;
                        end else if (pycore_latin1_is_lower(unit)) begin
                            if (!cls_prev_cased_r)
                                cls_title_ok_r <= 1'b0;
                            cls_saw_cased_r <= 1'b1;
                            cls_prev_cased_r <= 1'b1;
                        end else
                            cls_prev_cased_r <= 1'b0;
                    end
                    default: pred = 1'b1;
                endcase
                if (!pred)
                    cls_ok_r <= 1'b0;
                pos_r <= pos_r + 32'd1;
            end
        end
    endtask

    task automatic step_map();
        logic got, expands, next_cased;
        logic [31:0] unit, mu;
        logic [2:0] k;
        logic [31:0] nout;
        if (map_measuring_r) begin
            if (pos_r >= a_nchars_r) begin
                if (!map_changed_r && (map_extra_r == 32'd0) &&
                    (map_kmax_r == a_kind_r))
                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                else begin
                    nout = a_nchars_r + map_extra_r;
                    map_measuring_r <= 1'b0;
                    map_expand_r <= 1'b0;
                    map_prev_cased_r <= 1'b0;
                    pos_r <= 32'd0;
                    setup_copy(nout, map_kmax_r);
                    eng_r <= ENG_MAP;
                end
            end else begin
                fetch_unit_ab(SRC_A, pos_r, got, unit);
                if (got) begin
                    map_apply(unit, pos_r, map_prev_cased_r, mu, expands, next_cased);
                    if ((mu != unit) || expands)
                        map_changed_r <= 1'b1;
                    k = pycore_stracc_kind_of_unit(mu);
                    if (k > map_kmax_r)
                        map_kmax_r <= k;
                    if (expands)
                        map_extra_r <= map_extra_r + 32'd1;
                    map_prev_cased_r <= next_cased;
                    pos_r <= pos_r + 32'd1;
                end
            end
        end else if (out_idx_r >= dst_nchars_r)
            finish_copy();
        else if (!dest_can_take())
            issue_write(dst_word_addr_r, dst_word_r, MEM_WR_DST);
        else if (map_expand_r) begin
            consume_unit(map_second_unit());
            map_expand_r <= 1'b0;
            pos_r <= pos_r + 32'd1;
        end else begin
            fetch_unit_ab(SRC_A, pos_r, got, unit);
            if (got) begin
                map_apply(unit, pos_r, map_prev_cased_r, mu, expands, next_cased);
                consume_unit(mu);
                map_prev_cased_r <= next_cased;
                if (expands)
                    map_expand_r <= 1'b1;
                else
                    pos_r <= pos_r + 32'd1;
            end
        end
    endtask

    task automatic step_affix();
        logic got;
        logic [31:0] unit;
        logic [31:0] nout, start_u;
        if (match_i_r >= nlen_r) begin
            if (var_r == PY_SA_AFFIX_PREFIX)
                start_u = nlen_r;
            else
                start_u = 32'd0;
            nout = a_nchars_r - nlen_r;
            if (nout == 32'd0)
                set_res(pycore_make_short_str_entry(4'd0, 120'd0), heap_ptr_r);
            else begin
                src_idx_r <= start_u;
                op_r <= PY_SA_SLICE;
                setup_copy(nout, a_kind_r);
            end
        end else if (!have_hay_r) begin
            fetch_unit_ab(SRC_A, pos_r + match_i_r, got, unit);
            if (got) begin
                hay_unit_r <= unit;
                have_hay_r <= 1'b1;
            end
        end else begin
            fetch_unit_ab(SRC_B, match_i_r, got, unit);
            if (got) begin
                if (hay_unit_r != unit)
                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                else begin
                    have_hay_r <= 1'b0;
                    match_i_r <= match_i_r + 32'd1;
                end
            end
        end
    endtask

    task automatic step_zfill();
        logic got;
        logic [31:0] unit, nout;
        fetch_unit_ab(SRC_A, 32'd0, got, unit);
        if (got) begin
            map_expand_r <= (unit == 32'h2B) || (unit == 32'h2D);
            nout = dst_nchars_r;
            fill_unit_r <= 32'h30;
            setup_copy(nout, a_kind_r);
            op_r <= PY_SA_ZFILL;
            eng_r <= ENG_COPY;
        end
    endtask

    task automatic hold_long_done(
        input logic [PYCORE_ENTRY_WIDTH-1:0] entry,
        input logic [1:0] dest
    );
        unique case (dest)
            2'd0: begin
                part0_r <= entry;
                join_phase_r <= 4'd12;
            end
            2'd1: begin
                part2_r <= entry;
                join_phase_r <= 4'd13;
            end
            default: begin
                join_el_tag_r <= entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                join_el_val_r <= entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                join_phase_r <= 4'd4;
            end
        endcase
        hold_dest_r <= dest;
        eng_r <= ENG_SPLIT;
    endtask

    task automatic start_slice_hold(
        input logic [31:0] start_u,
        input logic [31:0] nout,
        input logic [1:0] dest
    );
        hold_dest_r <= dest;
        if (nout == 32'd0) begin
            hold_long_done(pycore_make_short_str_entry(4'd0, 120'd0), dest);
            copy_hold_r <= 1'b0;
        end else begin
            src_idx_r <= start_u;
            copy_hold_r <= 1'b1;
            op_r <= PY_SA_SLICE;
            setup_copy(nout, a_kind_r);
        end
    endtask

    task automatic split_hold_piece(
        input logic [31:0] start_u,
        input logic [31:0] nout,
        input logic [1:0] dest
    );
        if ((start_u == 32'd0) && (nout == a_nchars_r))
            hold_long_done(cmd_entry(a_tag_r, a_val_r), dest);
        else
            start_slice_hold(start_u, nout, dest);
    endtask

    task automatic split_part_miss();
        part0_r <= cmd_entry(a_tag_r, a_val_r);
        part2_r <= pycore_make_short_str_entry(4'd0, 120'd0);
        map_changed_r <= 1'b0;
        join_phase_r <= 4'd13;
    endtask

    task automatic step_expandtabs();
        logic got;
        logic [31:0] unit, ns, tabsize, col;
        tabsize = split_r;
        col = cmp_idx_r;
        if (map_measuring_r) begin
            if (pos_r >= a_nchars_r) begin
                if (!map_changed_r)
                    set_res(cmd_entry(a_tag_r, a_val_r), heap_ptr_r);
                else begin
                    map_measuring_r <= 1'b0;
                    pos_r <= 32'd0;
                    cmp_idx_r <= 32'd0;
                    new_idx_r <= 32'd0;
                    fill_unit_r <= 32'h20;
                    setup_copy(count_r, a_kind_r);
                    eng_r <= ENG_EXPAND;
                end
            end else begin
                fetch_unit_ab(SRC_A, pos_r, got, unit);
                if (got) begin
                    if (unit == 32'h09) begin
                        map_changed_r <= 1'b1;
                        if (tabsize == 32'd0) begin
                            // CPython: tabsize < 1 deletes the tab.
                        end else begin
                            ns = tabsize - (col % tabsize);
                            count_r <= count_r + ns;
                            cmp_idx_r <= col + ns;
                        end
                    end else if ((unit == 32'h0A) || (unit == 32'h0D)) begin
                        count_r <= count_r + 32'd1;
                        cmp_idx_r <= 32'd0;
                    end else begin
                        count_r <= count_r + 32'd1;
                        cmp_idx_r <= col + 32'd1;
                    end
                    pos_r <= pos_r + 32'd1;
                end
            end
        end else if (out_idx_r >= dst_nchars_r)
            finish_copy();
        else if (!dest_can_take())
            issue_write(dst_word_addr_r, dst_word_r, MEM_WR_DST);
        else if (new_idx_r != 32'd0) begin
            consume_unit(32'h20);
            new_idx_r <= new_idx_r - 32'd1;
        end else begin
            fetch_unit_ab(SRC_A, pos_r, got, unit);
            if (got) begin
                if (unit == 32'h09) begin
                    if (tabsize == 32'd0)
                        pos_r <= pos_r + 32'd1;
                    else begin
                        ns = tabsize - (cmp_idx_r % tabsize);
                        consume_unit(32'h20);
                        new_idx_r <= ns - 32'd1;
                        cmp_idx_r <= cmp_idx_r + ns;
                        pos_r <= pos_r + 32'd1;
                    end
                end else if ((unit == 32'h0A) || (unit == 32'h0D)) begin
                    consume_unit(unit);
                    cmp_idx_r <= 32'd0;
                    pos_r <= pos_r + 32'd1;
                end else begin
                    consume_unit(unit);
                    cmp_idx_r <= cmp_idx_r + 32'd1;
                    pos_r <= pos_r + 32'd1;
                end
            end
        end
    endtask

    task automatic step_split();
        logic got, is_part, is_lines, is_ws;
        logic [31:0] unit, nout, n, place, taddr, end_addr, buf_bytes, br;
        logic [PYCORE_ENTRY_WIDTH-1:0] empty_s;
        logic [3:0] mid_tag;
        logic [127:0] mid_val;
        empty_s = pycore_make_short_str_entry(4'd0, 120'd0);
        is_part = (var_r == PY_SA_SPLIT_PARTITION) ||
                  (var_r == PY_SA_SPLIT_RPARTITION);
        is_lines = (var_r == PY_SA_SPLIT_LINES);
        is_ws = !trim_has_cs_r && !is_lines;
        if (is_part) begin
            case (join_phase_r)
                4'd0: begin
                    if ((b_kind_r > a_kind_r) || (nlen_r > a_nchars_r))
                        split_part_miss();
                    else if (rfind_r && (pos_r + nlen_r > a_nchars_r))
                        split_part_miss();
                    else if (!rfind_r && (pos_r + nlen_r > a_nchars_r))
                        split_part_miss();
                    else if (!have_hay_r) begin
                        fetch_unit_ab(SRC_A, pos_r + match_i_r, got, unit);
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
                                if (rfind_r) begin
                                    if (pos_r == 32'd0)
                                        split_part_miss();
                                    else
                                        pos_r <= pos_r - 32'd1;
                                end else
                                    pos_r <= pos_r + 32'd1;
                            end else if (match_i_r + 32'd1 == nlen_r) begin
                                have_hay_r <= 1'b0;
                                map_changed_r <= 1'b1;
                                join_sum_r <= pos_r;
                                split_hold_piece(32'd0, pos_r, 2'd0);
                            end else begin
                                have_hay_r <= 1'b0;
                                match_i_r <= match_i_r + 32'd1;
                            end
                        end
                    end
                end
                4'd12: begin
                    nout = a_nchars_r - (join_sum_r + nlen_r);
                    split_hold_piece(join_sum_r + nlen_r, nout, 2'd1);
                end
                4'd13: begin
                    nout = pycore_tuple_alloc_bytes(32'd3);
                    place = pycore_heap_place(heap_ptr_r, nout);
                    end_addr = place + nout;
                    if (end_addr > HEAP_LIMIT)
                        set_trap(PY_TRAP_MEM_FAULT);
                    else begin
                        join_obj_r <= place;
                        join_buf_r <= end_addr;
                        join_i_r <= 32'd0;
                        join_phase_r <= 4'd14;
                    end
                end
                4'd14: begin
                    if (map_changed_r) begin
                        mid_tag = b_tag_r;
                        mid_val = b_val_r;
                    end else begin
                        mid_tag = empty_s[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                        mid_val = empty_s[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                    end
                    case (join_i_r[2:0])
                        3'd0: issue_write(pycore_tuple_val_addr(join_obj_r, 32'd0),
                            part0_r[PYCORE_VAL_MSB:PYCORE_VAL_LSB], MEM_WR_DST);
                        3'd1: issue_write(pycore_tuple_tag_addr(join_obj_r, 32'd0),
                            {124'b0, part0_r[PYCORE_TAG_MSB:PYCORE_TAG_LSB]},
                            MEM_WR_DST);
                        3'd2: issue_write(pycore_tuple_val_addr(join_obj_r, 32'd1),
                            mid_val, MEM_WR_DST);
                        3'd3: issue_write(pycore_tuple_tag_addr(join_obj_r, 32'd1),
                            {124'b0, mid_tag}, MEM_WR_DST);
                        3'd4: issue_write(pycore_tuple_val_addr(join_obj_r, 32'd2),
                            part2_r[PYCORE_VAL_MSB:PYCORE_VAL_LSB], MEM_WR_DST);
                        default: issue_write(pycore_tuple_tag_addr(join_obj_r, 32'd2),
                            {124'b0, part2_r[PYCORE_TAG_MSB:PYCORE_TAG_LSB]},
                            MEM_WR_DST);
                    endcase
                    if (join_i_r == 32'd5)
                        join_phase_r <= 4'd15;
                    else
                        join_i_r <= join_i_r + 32'd1;
                end
                4'd15: begin
                    set_res(pycore_make_entry(PY_TAG_TUPLE,
                        {64'd3, {32'd0, join_obj_r}}), join_buf_r);
                end
                default: set_trap(PY_TRAP_TYPE);
            endcase
        end else begin
            case (join_phase_r)
                // ---- measure ----
                4'd0: begin
                    if (trim_has_cs_r && (count_r == 32'd0)) begin
                        join_n_r <= 32'd1;
                        split_r <= 32'd0;
                        join_fill_sep_r <= 1'b0;
                        join_phase_r <= 4'd1;
                    end else if (pos_r >= a_nchars_r) begin
                        if (is_ws)
                            n = join_n_r + {31'b0, trim_in_cs_r};
                        else
                            n = join_n_r;
                        if (trim_has_cs_r) begin
                            n = cmp_idx_r + 32'd1;
                            if (rfind_r && (cmp_idx_r > count_r)) begin
                                split_r <= cmp_idx_r - count_r;
                                n = count_r + 32'd1;
                            end else
                                split_r <= 32'd0;
                            join_n_r <= n;
                            join_fill_sep_r <= 1'b0;
                            join_phase_r <= 4'd1;
                        end else if (is_lines) begin
                            join_n_r <= n;
                            join_fill_sep_r <= 1'b0;
                            join_phase_r <= 4'd1;
                        end else begin
                            join_n_r <= n;
                            if (rfind_r && (n > (count_r + 32'd1))) begin
                                join_n_r <= count_r + 32'd1;
                                pos_r <= a_nchars_r - 32'd1;
                                cmp_idx_r <= 32'd0;
                                trim_in_cs_r <= 1'b0;
                                replace_copy_hay_r <= 1'b0;
                                join_fill_sep_r <= 1'b1;
                                join_phase_r <= 4'd3;
                            end else begin
                                join_fill_sep_r <= 1'b0;
                                join_phase_r <= 4'd1;
                            end
                        end
                    end else if (is_ws) begin
                        fetch_unit_ab(SRC_A, pos_r, got, unit);
                        if (got) begin
                            if (pycore_is_unicode_space(unit)) begin
                                if (trim_in_cs_r) begin
                                    join_n_r <= join_n_r + 32'd1;
                                    trim_in_cs_r <= 1'b0;
                                end
                                pos_r <= pos_r + 32'd1;
                            end else if (!rfind_r && (join_n_r >= count_r)) begin
                                join_n_r <= join_n_r + 32'd1;
                                pos_r <= a_nchars_r;
                                trim_in_cs_r <= 1'b0;
                                replace_copy_hay_r <= 1'b1;
                            end else begin
                                trim_in_cs_r <= 1'b1;
                                pos_r <= pos_r + 32'd1;
                            end
                        end
                    end else if (is_lines) begin
                        if (have_hay_r) begin
                            fetch_unit_ab(SRC_A, pos_r + 32'd1, got, unit);
                            if (got) begin
                                join_n_r <= join_n_r + 32'd1;
                                pos_r <= pos_r + ((unit == 32'h0A) ? 32'd2 : 32'd1);
                                have_hay_r <= 1'b0;
                            end
                        end else begin
                            fetch_unit_ab(SRC_A, pos_r, got, unit);
                            if (got) begin
                                if (pycore_is_unicode_linebreak(unit)) begin
                                    if ((unit == 32'h0D) &&
                                        (pos_r + 32'd1 < a_nchars_r))
                                        have_hay_r <= 1'b1;
                                    else begin
                                        join_n_r <= join_n_r + 32'd1;
                                        pos_r <= pos_r + 32'd1;
                                    end
                                end else begin
                                    pos_r <= pos_r + 32'd1;
                                    if (pos_r + 32'd1 >= a_nchars_r)
                                        join_n_r <= join_n_r + 32'd1;
                                end
                            end
                        end
                    end else begin
                        // sep measure
                        if (pos_r + nlen_r > a_nchars_r)
                            pos_r <= a_nchars_r;
                        else if (!have_hay_r) begin
                            fetch_unit_ab(SRC_A, pos_r + match_i_r, got, unit);
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
                                    pos_r <= pos_r + 32'd1;
                                end else if (match_i_r + 32'd1 == nlen_r) begin
                                    have_hay_r <= 1'b0;
                                    match_i_r <= 32'd0;
                                    cmp_idx_r <= cmp_idx_r + 32'd1;
                                    pos_r <= pos_r + nlen_r;
                                    if (!rfind_r &&
                                        (cmp_idx_r + 32'd1 == count_r))
                                        pos_r <= a_nchars_r;
                                end else begin
                                    have_hay_r <= 1'b0;
                                    match_i_r <= match_i_r + 32'd1;
                                end
                            end
                        end
                    end
                end
                // ---- rsplit whitespace: find leftover cut from the right ----
                4'd3: begin
                    if (replace_copy_hay_r) begin
                        right_start_r <= 32'd0;
                        join_phase_r <= 4'd1;
                    end else begin
                        fetch_unit_ab(SRC_A, pos_r, got, unit);
                        if (got) begin
                            if (!trim_in_cs_r) begin
                                if (pycore_is_unicode_space(unit)) begin
                                    if (pos_r == 32'd0) begin
                                        right_start_r <= 32'd0;
                                        join_phase_r <= 4'd1;
                                    end else
                                        pos_r <= pos_r - 32'd1;
                                end else if (cmp_idx_r >= count_r) begin
                                    right_start_r <= pos_r + 32'd1;
                                    join_phase_r <= 4'd1;
                                end else
                                    trim_in_cs_r <= 1'b1;
                            end else if (!pycore_is_unicode_space(unit)) begin
                                if (pos_r == 32'd0) begin
                                    cmp_idx_r <= cmp_idx_r + 32'd1;
                                    trim_in_cs_r <= 1'b0;
                                    replace_copy_hay_r <= 1'b1;
                                end else
                                    pos_r <= pos_r - 32'd1;
                            end else begin
                                cmp_idx_r <= cmp_idx_r + 32'd1;
                                trim_in_cs_r <= 1'b0;
                            end
                        end
                    end
                end
                // ---- allocate list ----
                4'd1: begin
                    n = join_n_r;
                    place = pycore_list_place_obj(heap_ptr_r);
                    if (n == 32'd0) begin
                        end_addr = place + 32'd32;
                        if (end_addr > HEAP_LIMIT)
                            set_trap(PY_TRAP_MEM_FAULT);
                        else begin
                            join_obj_r <= place;
                            join_buf_r <= 32'd0;
                            heap_ptr_r <= end_addr;
                            join_phase_r <= 4'd6;
                        end
                    end else begin
                        buf_bytes = n << 5;
                        taddr = pycore_list_place_buf(heap_ptr_r, n);
                        end_addr = taddr + buf_bytes;
                        if (end_addr > HEAP_LIMIT)
                            set_trap(PY_TRAP_MEM_FAULT);
                        else begin
                            join_obj_r <= place;
                            join_buf_r <= taddr;
                            heap_ptr_r <= end_addr;
                            join_i_r <= 32'd0;
                            pos_r <= 32'd0;
                            join_sum_r <= 32'd0;
                            hay_pos_r <= 32'd0;
                            have_hay_r <= 1'b0;
                            match_i_r <= 32'd0;
                            trim_in_cs_r <= 1'b0;
                            join_phase_r <= 4'd2;
                        end
                    end
                end
                // ---- emit scan ----
                4'd2: begin
                    if (join_i_r >= join_n_r)
                        join_phase_r <= 4'd6;
                    else if (join_fill_sep_r) begin
                        hay_pos_r <= right_start_r;
                        split_hold_piece(32'd0, right_start_r, 2'd2);
                        join_fill_sep_r <= 1'b0;
                    end else if (trim_has_cs_r) begin
                        if (join_i_r + 32'd1 == join_n_r) begin
                            nout = a_nchars_r - join_sum_r;
                            hay_pos_r <= a_nchars_r;
                            split_hold_piece(join_sum_r, nout, 2'd2);
                        end else begin
                            pos_r <= join_sum_r;
                            match_i_r <= 32'd0;
                            have_hay_r <= 1'b0;
                            join_phase_r <= 4'd8;
                        end
                    end else if (is_lines) begin
                        if (have_hay_r) begin
                            fetch_unit_ab(SRC_A, pos_r + 32'd1, got, unit);
                            if (got) begin
                                br = (unit == 32'h0A) ? 32'd2 : 32'd1;
                                nout = map_expand_r
                                     ? (pos_r + br - join_sum_r)
                                     : (pos_r - join_sum_r);
                                hay_pos_r <= pos_r + br;
                                have_hay_r <= 1'b0;
                                split_hold_piece(join_sum_r, nout, 2'd2);
                            end
                        end else if (pos_r >= a_nchars_r) begin
                            nout = a_nchars_r - join_sum_r;
                            hay_pos_r <= a_nchars_r;
                            split_hold_piece(join_sum_r, nout, 2'd2);
                        end else begin
                            fetch_unit_ab(SRC_A, pos_r, got, unit);
                            if (got) begin
                                if (pycore_is_unicode_linebreak(unit)) begin
                                    if ((unit == 32'h0D) &&
                                        (pos_r + 32'd1 < a_nchars_r))
                                        have_hay_r <= 1'b1;
                                    else begin
                                        nout = map_expand_r
                                             ? (pos_r + 32'd1 - join_sum_r)
                                             : (pos_r - join_sum_r);
                                        hay_pos_r <= pos_r + 32'd1;
                                        split_hold_piece(join_sum_r, nout, 2'd2);
                                    end
                                end else
                                    pos_r <= pos_r + 32'd1;
                            end
                        end
                    end else begin
                        // whitespace emit
                        if (replace_copy_hay_r &&
                            (join_i_r + 32'd1 == join_n_r)) begin
                            if (pos_r >= a_nchars_r) begin
                                hay_pos_r <= a_nchars_r;
                                split_hold_piece(pos_r, 32'd0, 2'd2);
                            end else begin
                                fetch_unit_ab(SRC_A, pos_r, got, unit);
                                if (got) begin
                                    if (pycore_is_unicode_space(unit))
                                        pos_r <= pos_r + 32'd1;
                                    else begin
                                        hay_pos_r <= a_nchars_r;
                                        split_hold_piece(pos_r,
                                            a_nchars_r - pos_r, 2'd2);
                                    end
                                end
                            end
                        end else if (pos_r >= a_nchars_r) begin
                            nout = pos_r - join_sum_r;
                            hay_pos_r <= pos_r;
                            split_hold_piece(join_sum_r, nout, 2'd2);
                        end else begin
                            fetch_unit_ab(SRC_A, pos_r, got, unit);
                            if (got) begin
                                if (pycore_is_unicode_space(unit)) begin
                                    if (trim_in_cs_r) begin
                                        nout = pos_r - join_sum_r;
                                        hay_pos_r <= pos_r;
                                        split_hold_piece(join_sum_r, nout, 2'd2);
                                        trim_in_cs_r <= 1'b0;
                                    end else
                                        pos_r <= pos_r + 32'd1;
                                end else begin
                                    if (!trim_in_cs_r) begin
                                        join_sum_r <= pos_r;
                                        trim_in_cs_r <= 1'b1;
                                    end
                                    pos_r <= pos_r + 32'd1;
                                end
                            end
                        end
                    end
                end
                4'd8: begin
                    if (pos_r + nlen_r > a_nchars_r) begin
                        nout = a_nchars_r - join_sum_r;
                        hay_pos_r <= a_nchars_r;
                        split_hold_piece(join_sum_r, nout, 2'd2);
                    end else if (!have_hay_r) begin
                        fetch_unit_ab(SRC_A, pos_r + match_i_r, got, unit);
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
                                pos_r <= pos_r + 32'd1;
                            end else if (match_i_r + 32'd1 == nlen_r) begin
                                have_hay_r <= 1'b0;
                                match_i_r <= 32'd0;
                                if (split_r != 32'd0) begin
                                    split_r <= split_r - 32'd1;
                                    pos_r <= pos_r + nlen_r;
                                end else begin
                                    hay_pos_r <= pos_r;
                                    nout = pos_r - join_sum_r;
                                    split_hold_piece(join_sum_r, nout, 2'd2);
                                end
                            end else begin
                                have_hay_r <= 1'b0;
                                match_i_r <= match_i_r + 32'd1;
                            end
                        end
                    end
                end
                4'd4: begin
                    issue_write(pycore_list_val_addr(join_buf_r, join_i_r),
                        join_el_val_r, MEM_WR_DST);
                    join_phase_r <= 4'd5;
                end
                4'd5: begin
                    issue_write(pycore_list_tag_addr(join_buf_r, join_i_r),
                        {124'b0, join_el_tag_r}, MEM_WR_DST);
                    if (trim_has_cs_r) begin
                        join_sum_r <= hay_pos_r + nlen_r;
                        pos_r <= hay_pos_r + nlen_r;
                    end else begin
                        join_sum_r <= hay_pos_r;
                        pos_r <= hay_pos_r;
                    end
                    trim_in_cs_r <= 1'b0;
                    have_hay_r <= 1'b0;
                    match_i_r <= 32'd0;
                    if (join_i_r + 32'd1 >= join_n_r)
                        join_phase_r <= 4'd6;
                    else begin
                        join_i_r <= join_i_r + 32'd1;
                        join_phase_r <= 4'd2;
                    end
                end
                4'd6: begin
                    issue_write(join_obj_r,
                        pycore_list_header({32'd0, join_n_r}, {32'd0, join_n_r}),
                        MEM_WR_DST);
                    join_phase_r <= 4'd7;
                end
                4'd7: begin
                    issue_write(join_obj_r + 32'd16,
                        {64'd0, {32'd0, join_buf_r}}, MEM_WR_DST);
                    join_phase_r <= 4'd9;
                end
                4'd9: begin
                    set_res(pycore_make_mut(PY_MUT_LIST, {32'd0, join_obj_r}, 1'b0),
                            heap_ptr_r);
                end
                default: set_trap(PY_TRAP_TYPE);
            endcase
        end
    endtask
endmodule
