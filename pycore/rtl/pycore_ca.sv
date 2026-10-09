`include "pycore_defs.svh"
`include "pycore_ca_defs.svh"

// Container accelerator. One command at a time; data-ready and
// container-ready are the same cycle. The core is frozen, so this port
// is the only dmem master.
//
// Placement matches excore firmware (raw heap_ptr, not line-aligned):
//   L_APPEND  full list: new_cap = cap ? cap*2 : 4, copy, append
//   L_EXTEND  in place when cap >= len+src, else doubling grow-to-fit
//   L_DEL     shift [idx+1, len) down; cap and heap unchanged
//   D_GROW    new order then table, rehash occupied slots, insert key
//   S_GROW    new element table, rehash, insert element
// A short heap abandons the command before any write.
module pycore_ca (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    input  logic                          cmd_valid_i,
    output logic                          cmd_ready_o,
    input  logic [6:0]                    cmd_op_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_a_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_b_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_c_i,
    input  logic [31:0]                   cmd_heap_ptr_i,
    input  logic [31:0]                   cmd_heap_limit_i,

    output logic                          dr_valid_o,
    input  logic                          dr_ready_i,
    output logic                          dr_ok_o,
    output logic                          dr_short_o,
    output logic                          dr_fault_o,
    output logic [31:0]                   dr_heap_o,
    output logic [31:0]                   dr_need_o,
    output logic                          cr_valid_o,
    output logic                          ca_idle_o,

    output logic                          req_o,
    output logic                          we_o,
    output logic [31:0]                   addr_o,
    output logic [127:0]                  wdata_o,
    input  logic                          ack_i,
    input  logic                          fault_i,
    input  logic [127:0]                  rdata_i
);
    typedef enum logic [6:0] {
        PH_IDLE,
        PH_HDR, PH_ITEM, PH_CV, PH_WV, PH_CT, PH_WT, PH_AV, PH_AT, PH_HH, PH_HI,
        LE_HDR, LE_ITEM, LE_SHDR, LE_SITEM, LE_PLAN,
        LE_CV, LE_WV, LE_CT, LE_WT, LE_HH, LE_HI,
        LD_HDR, LD_ITEM, LD_PLAN, LD_RV, LD_WV, LD_RT, LD_WT, LD_HH,
        DG_H0, DG_H1, DG_H2, DG_PLAN,
        DG_OR, DG_OW, DG_OT, DG_OTW, DG_Z,
        DG_RT, DG_RV, DG_VV, DG_VT, DG_PR,
        DG_WK, DG_WKT, DG_WV, DG_WVT, DG_INS,
        DG_OA, DG_OAT, DG_HH, DG_HM, DG_HP,
        SG_H0, SG_H1, SG_PLAN, SG_Z,
        SG_RT, SG_RV, SG_PR, SG_WV, SG_WT, SG_INS, SG_HH, SG_HP
    } ph_e;

    ph_e  phase_r;
    logic busy_r;
    logic req_r;

    logic [31:0] obj_r, old_buf_r, new_buf_r, new_end_r;
    logic [31:0] len_r, cap_r, new_cap_r, idx_r;
    logic [31:0] src_len_r, src_buf_r, del_idx_r;
    logic [3:0]  src_tag_r;
    logic [127:0] src_val_r;
    logic        inplace_r, copy_src_r, ins_new_r;
    logic [31:0] used_r, slots_r, order_len_r, version_r;
    logic [31:0] order_ptr_r, order_new_r, probe_r, probe_n_r;
    logic [3:0]  nk_tag_r, nv_tag_r;
    logic [127:0] nk_val_r, nv_val_r;
    logic [127:0] kv_tag_r, kv_val_r, vv_tag_r, vv_val_r;
    logic [127:0] hold_r;
    logic [3:0]  elem_tag_r;
    logic [127:0] elem_val_r;
    logic        dr_valid_r, dr_ok_r, dr_short_r, dr_fault_r;
    logic [31:0] dr_heap_r, dr_need_r;

    assign cmd_ready_o = (phase_r == PH_IDLE) && !dr_valid_r;
    assign dr_valid_o  = dr_valid_r;
    assign dr_ok_o     = dr_ok_r;
    assign dr_short_o  = dr_short_r;
    assign dr_fault_o  = dr_fault_r;
    assign dr_heap_o   = dr_heap_r;
    assign dr_need_o   = dr_need_r;
    assign cr_valid_o  = dr_valid_r && dr_ok_r;
    assign ca_idle_o   = (phase_r == PH_IDLE) && !dr_valid_r && !req_r;
    assign req_o       = req_r;
    assign we_o        = we_r;
    assign addr_o      = addr_r;
    assign wdata_o     = wdata_r;

    logic        we_r;
    logic [31:0] addr_r;
    logic [127:0] wdata_r;

    function automatic logic [31:0] elem_addr(input logic [31:0] base,
                                              input logic [31:0] i);
        elem_addr = base + (i << 5);
    endfunction

    function automatic logic [31:0] dslot_addr(input logic [31:0] base,
                                               input logic [31:0] i);
        dslot_addr = base + (i << 6);
    endfunction

    // new_cap = max(cap ? cap*2 : 4, need), doubling until >= need.
    function automatic logic [31:0] ca_ext_cap(input logic [31:0] cap,
                                               input logic [31:0] need);
        logic [31:0] n;
        integer k;
        begin
            n = (cap == 32'd0) ? 32'd4 : (cap << 1);
            for (k = 0; k < 27; k = k + 1)
                if ((n < need) && (n[31] == 1'b0))
                    n = n << 1;
            ca_ext_cap = n;
        end
    endfunction

    // Dict/set grow: 4x under 50000 used else 2x, min 8, pow2, strictly
    // above used, and at least 2*old_slots when the old table exists.
    function automatic logic [31:0] ca_grow_slots(input logic [31:0] used,
                                                  input logic [31:0] old_slots);
        logic [31:0] target, slots;
        integer k;
        begin
            if (used < 32'd50000)
                target = used << 2;
            else
                target = used << 1;
            if (target < 32'd8)
                target = 32'd8;
            slots = 32'd8;
            for (k = 0; k < 27; k = k + 1)
                if ((slots < target) && (slots[31] == 1'b0))
                    slots = slots << 1;
            for (k = 0; k < 27; k = k + 1)
                if ((used >= slots) && (slots[31] == 1'b0))
                    slots = slots << 1;
            if ((old_slots != 32'd0) && (slots < (old_slots << 1)) &&
                (old_slots[31] == 1'b0))
                slots = old_slots << 1;
            ca_grow_slots = slots;
        end
    endfunction

    function automatic logic [31:0] ca_hash_idx(input logic [3:0] tag,
                                                input logic [127:0] val,
                                                input logic [31:0] slots);
        ca_hash_idx = pycore_dict_key_hash(tag, val) & (slots - 32'd1);
    endfunction

    function automatic logic ca_skip_slot(input logic [127:0] tag_word);
        ca_skip_slot = pycore_dict_slot_empty(tag_word) ||
                       pycore_dict_tombstone(tag_word[3:0]);
    endfunction

`define CA_ISSUE(WE, ADDR, DATA) \
    we_r <= (WE); addr_r <= (ADDR); wdata_r <= (DATA); req_r <= 1'b1; busy_r <= 1'b1
`define CA_OK(HEAP) \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b1; dr_short_r <= 1'b0; dr_fault_r <= 1'b0; \
    dr_heap_r <= (HEAP); dr_need_r <= 32'd0; phase_r <= PH_IDLE; req_r <= 1'b0; busy_r <= 1'b0
`define CA_SHORT(NEEDV) \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b0; dr_short_r <= 1'b1; dr_fault_r <= 1'b0; \
    dr_heap_r <= cmd_heap_ptr_i; dr_need_r <= (NEEDV); phase_r <= PH_IDLE; \
    req_r <= 1'b0; busy_r <= 1'b0
`define CA_FAULT \
    dr_valid_r <= 1'b1; dr_ok_r <= 1'b0; dr_short_r <= 1'b0; dr_fault_r <= 1'b1; \
    dr_heap_r <= cmd_heap_ptr_i; dr_need_r <= 32'd0; phase_r <= PH_IDLE; \
    req_r <= 1'b0; busy_r <= 1'b0

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [31:0] len_w, cap_w, ncap, nend, need, di, sbase, dbase;
        logic [31:0] probe_w, tbase, tend, region, ord_b;
        logic [32:0] sum;
        if (!rst_n_i) begin
            phase_r     <= PH_IDLE;
            busy_r      <= 1'b0;
            req_r       <= 1'b0;
            we_r        <= 1'b0;
            addr_r      <= '0;
            wdata_r     <= '0;
            dr_valid_r  <= 1'b0;
            dr_ok_r     <= 1'b0;
            dr_short_r  <= 1'b0;
            dr_fault_r  <= 1'b0;
            dr_heap_r   <= '0;
            dr_need_r   <= '0;
            obj_r       <= '0;
            old_buf_r   <= '0;
            new_buf_r   <= '0;
            new_end_r   <= '0;
            len_r       <= '0;
            cap_r       <= '0;
            new_cap_r   <= '0;
            idx_r       <= '0;
            src_len_r   <= '0;
            src_buf_r   <= '0;
            del_idx_r   <= '0;
            src_tag_r   <= '0;
            src_val_r   <= '0;
            inplace_r   <= 1'b0;
            copy_src_r  <= 1'b0;
            ins_new_r   <= 1'b0;
            used_r      <= '0;
            slots_r     <= '0;
            order_len_r <= '0;
            version_r   <= '0;
            order_ptr_r <= '0;
            order_new_r <= '0;
            probe_r     <= '0;
            probe_n_r   <= '0;
            nk_tag_r    <= '0;
            nv_tag_r    <= '0;
            nk_val_r    <= '0;
            nv_val_r    <= '0;
            kv_tag_r    <= '0;
            kv_val_r    <= '0;
            vv_tag_r    <= '0;
            vv_val_r    <= '0;
            hold_r      <= '0;
            elem_tag_r  <= '0;
            elem_val_r  <= '0;
        end else begin
            if (dr_valid_r && dr_ready_i) begin
                dr_valid_r <= 1'b0;
                dr_ok_r    <= 1'b0;
                dr_short_r <= 1'b0;
                dr_fault_r <= 1'b0;
            end
            if (req_r) begin
                req_r <= 1'b0;
            end else if (busy_r && ack_i) begin
                busy_r <= 1'b0;
                if (fault_i) begin
                    `CA_FAULT;
                end else unique case (phase_r)
                    PH_HDR: begin
                        len_w = rdata_i[31:0];
                        cap_w = rdata_i[95:64];
                        len_r <= len_w;
                        cap_r <= cap_w;
                        phase_r <= PH_ITEM;
                        `CA_ISSUE(1'b0, obj_r + 32'd16, 128'd0);
                    end
                    PH_ITEM: begin
                        old_buf_r <= rdata_i[31:0];
                        ncap = (cap_r == 32'd0) ? 32'd4 : (cap_r << 1);
                        new_cap_r <= ncap;
                        new_buf_r <= cmd_heap_ptr_i;
                        nend = cmd_heap_ptr_i + (ncap << 5);
                        new_end_r <= nend;
                        if (nend < cmd_heap_ptr_i || nend > cmd_heap_limit_i) begin
                            need = nend - cmd_heap_ptr_i;
                            `CA_SHORT(need);
                        end else if (len_r == 32'd0) begin
                            phase_r <= PH_AV;
                            `CA_ISSUE(1'b1, elem_addr(cmd_heap_ptr_i, 32'd0), elem_val_r);
                        end else begin
                            idx_r   <= 32'd0;
                            phase_r <= PH_CV;
                            `CA_ISSUE(1'b0, elem_addr(rdata_i[31:0], 32'd0), 128'd0);
                        end
                    end
                    PH_CV: begin
                        hold_r  <= rdata_i;
                        phase_r <= PH_WV;
                        `CA_ISSUE(1'b1, elem_addr(new_buf_r, idx_r), rdata_i);
                    end
                    PH_WV: begin
                        phase_r <= PH_CT;
                        `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r) + 32'd16, 128'd0);
                    end
                    PH_CT: begin
                        phase_r <= PH_WT;
                        `CA_ISSUE(1'b1, elem_addr(new_buf_r, idx_r) + 32'd16,
                              {124'b0, rdata_i[3:0]});
                    end
                    PH_WT: begin
                        if (idx_r + 32'd1 == len_r) begin
                            phase_r <= PH_AV;
                            `CA_ISSUE(1'b1, elem_addr(new_buf_r, len_r), elem_val_r);
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= PH_CV;
                            `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r + 32'd1), 128'd0);
                        end
                    end
                    PH_AV: begin
                        phase_r <= PH_AT;
                        `CA_ISSUE(1'b1, elem_addr(new_buf_r, len_r) + 32'd16,
                              {124'b0, elem_tag_r});
                    end
                    PH_AT: begin
                        phase_r <= PH_HH;
                        `CA_ISSUE(1'b1, obj_r,
                              {32'b0, new_cap_r, 32'b0, len_r + 32'd1});
                    end
                    PH_HH: begin
                        phase_r <= PH_HI;
                        `CA_ISSUE(1'b1, obj_r + 32'd16, {96'b0, new_buf_r});
                    end
                    PH_HI: begin
                        `CA_OK(new_end_r);
                    end

                    LE_HDR: begin
                        len_r   <= rdata_i[31:0];
                        cap_r   <= rdata_i[95:64];
                        phase_r <= LE_ITEM;
                        `CA_ISSUE(1'b0, obj_r + 32'd16, 128'd0);
                    end
                    LE_ITEM: begin
                        old_buf_r <= rdata_i[31:0];
                        if (src_tag_r == PY_TAG_TUPLE) begin
                            src_len_r <= src_val_r[95:64];
                            src_buf_r <= src_val_r[31:0];
                            phase_r   <= LE_PLAN;
                        end else if (src_val_r[31:0] == obj_r) begin
                            src_len_r <= len_r;
                            src_buf_r <= rdata_i[31:0];
                            phase_r   <= LE_PLAN;
                        end else begin
                            phase_r <= LE_SHDR;
                            `CA_ISSUE(1'b0, src_val_r[31:0], 128'd0);
                        end
                    end
                    LE_SHDR: begin
                        src_len_r <= rdata_i[31:0];
                        phase_r   <= LE_SITEM;
                        `CA_ISSUE(1'b0, src_val_r[31:0] + 32'd16, 128'd0);
                    end
                    LE_SITEM: begin
                        src_buf_r <= rdata_i[31:0];
                        phase_r   <= LE_PLAN;
                    end
                    LE_CV: begin
                        dbase = inplace_r ? old_buf_r : new_buf_r;
                        di    = copy_src_r ? (len_r + idx_r) : idx_r;
                        phase_r <= LE_WV;
                        `CA_ISSUE(1'b1, elem_addr(dbase, di), rdata_i);
                    end
                    LE_WV: begin
                        sbase = copy_src_r ? src_buf_r : old_buf_r;
                        phase_r <= LE_CT;
                        `CA_ISSUE(1'b0, elem_addr(sbase, idx_r) + 32'd16, 128'd0);
                    end
                    LE_CT: begin
                        dbase = inplace_r ? old_buf_r : new_buf_r;
                        di    = copy_src_r ? (len_r + idx_r) : idx_r;
                        phase_r <= LE_WT;
                        `CA_ISSUE(1'b1, elem_addr(dbase, di) + 32'd16, rdata_i);
                    end
                    LE_WT: begin
                        region = copy_src_r ? src_len_r : len_r;
                        sbase  = copy_src_r ? src_buf_r : old_buf_r;
                        if (idx_r + 32'd1 == region) begin
                            if (!copy_src_r && (src_len_r != 32'd0)) begin
                                copy_src_r <= 1'b1;
                                idx_r      <= 32'd0;
                                phase_r    <= LE_CV;
                                `CA_ISSUE(1'b0, elem_addr(src_buf_r, 32'd0), 128'd0);
                            end else begin
                                phase_r <= LE_HH;
                                `CA_ISSUE(1'b1, obj_r,
                                      {32'b0, new_cap_r, 32'b0, len_r + src_len_r});
                            end
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= LE_CV;
                            `CA_ISSUE(1'b0, elem_addr(sbase, idx_r + 32'd1), 128'd0);
                        end
                    end
                    LE_HH: begin
                        if (inplace_r) begin
                            `CA_OK(cmd_heap_ptr_i);
                        end else begin
                            phase_r <= LE_HI;
                            `CA_ISSUE(1'b1, obj_r + 32'd16, {96'b0, new_buf_r});
                        end
                    end
                    LE_HI: begin
                        `CA_OK(new_end_r);
                    end

                    LD_HDR: begin
                        len_r   <= rdata_i[31:0];
                        cap_r   <= rdata_i[95:64];
                        phase_r <= LD_ITEM;
                        `CA_ISSUE(1'b0, obj_r + 32'd16, 128'd0);
                    end
                    LD_ITEM: begin
                        old_buf_r <= rdata_i[31:0];
                        phase_r   <= LD_PLAN;
                    end
                    LD_RV: begin
                        phase_r <= LD_WV;
                        `CA_ISSUE(1'b1, elem_addr(old_buf_r, idx_r), rdata_i);
                    end
                    LD_WV: begin
                        phase_r <= LD_RT;
                        `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                    end
                    LD_RT: begin
                        phase_r <= LD_WT;
                        `CA_ISSUE(1'b1, elem_addr(old_buf_r, idx_r) + 32'd16, rdata_i);
                    end
                    LD_WT: begin
                        if (idx_r + 32'd2 == len_r) begin
                            phase_r <= LD_HH;
                            `CA_ISSUE(1'b1, obj_r,
                                  {32'b0, cap_r, 32'b0, len_r - 32'd1});
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= LD_RV;
                            `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r + 32'd2), 128'd0);
                        end
                    end
                    LD_HH: begin
                        `CA_OK(cmd_heap_ptr_i);
                    end

                    DG_H0: begin
                        used_r  <= rdata_i[31:0];
                        slots_r <= rdata_i[95:64];
                        phase_r <= DG_H1;
                        `CA_ISSUE(1'b0, obj_r + 32'd16, 128'd0);
                    end
                    DG_H1: begin
                        order_len_r <= rdata_i[31:0];
                        version_r   <= rdata_i[95:64];
                        phase_r     <= DG_H2;
                        `CA_ISSUE(1'b0, obj_r + 32'd32, 128'd0);
                    end
                    DG_H2: begin
                        old_buf_r   <= rdata_i[31:0];
                        order_ptr_r <= rdata_i[95:64];
                        phase_r     <= DG_PLAN;
                    end
                    DG_OR: begin
                        phase_r <= DG_OW;
                        `CA_ISSUE(1'b1, elem_addr(order_new_r, idx_r), rdata_i);
                    end
                    DG_OW: begin
                        phase_r <= DG_OT;
                        `CA_ISSUE(1'b0, elem_addr(order_ptr_r, idx_r) + 32'd16, 128'd0);
                    end
                    DG_OT: begin
                        phase_r <= DG_OTW;
                        `CA_ISSUE(1'b1, elem_addr(order_new_r, idx_r) + 32'd16,
                              {96'b0, rdata_i[31:0]});
                    end
                    DG_OTW: begin
                        if (idx_r + 32'd1 == order_len_r) begin
                            idx_r   <= 32'd0;
                            phase_r <= DG_Z;
                            `CA_ISSUE(1'b1, dslot_addr(new_buf_r, 32'd0) + 32'd16, 128'd0);
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= DG_OR;
                            `CA_ISSUE(1'b0, elem_addr(order_ptr_r, idx_r + 32'd1), 128'd0);
                        end
                    end
                    DG_Z: begin
                        if (idx_r + 32'd1 == new_cap_r) begin
                            if (slots_r == 32'd0) begin
                                phase_r <= DG_INS;
                            end else begin
                                idx_r   <= 32'd0;
                                phase_r <= DG_RT;
                                `CA_ISSUE(1'b0, dslot_addr(old_buf_r, 32'd0) + 32'd16, 128'd0);
                            end
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= DG_Z;
                            `CA_ISSUE(1'b1, dslot_addr(new_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                        end
                    end
                    DG_RT: begin
                        if (ca_skip_slot(rdata_i)) begin
                            if (idx_r + 32'd1 == slots_r) begin
                                phase_r <= DG_INS;
                            end else begin
                                idx_r   <= idx_r + 32'd1;
                                `CA_ISSUE(1'b0, dslot_addr(old_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                            end
                        end else begin
                            kv_tag_r <= rdata_i;
                            phase_r  <= DG_RV;
                            `CA_ISSUE(1'b0, dslot_addr(old_buf_r, idx_r), 128'd0);
                        end
                    end
                    DG_RV: begin
                        kv_val_r <= rdata_i;
                        phase_r  <= DG_VV;
                        `CA_ISSUE(1'b0, dslot_addr(old_buf_r, idx_r) + 32'd32, 128'd0);
                    end
                    DG_VV: begin
                        vv_val_r <= rdata_i;
                        phase_r  <= DG_VT;
                        `CA_ISSUE(1'b0, dslot_addr(old_buf_r, idx_r) + 32'd48, 128'd0);
                    end
                    DG_VT: begin
                        vv_tag_r  <= rdata_i;
                        probe_w   = ca_hash_idx(kv_tag_r[3:0], kv_val_r, new_cap_r);
                        probe_r   <= probe_w;
                        probe_n_r <= 32'd0;
                        ins_new_r <= 1'b0;
                        phase_r   <= DG_PR;
                        `CA_ISSUE(1'b0, dslot_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                    end
                    DG_PR: begin
                        if (pycore_dict_slot_empty(rdata_i)) begin
                            phase_r <= DG_WK;
                            `CA_ISSUE(1'b1, dslot_addr(new_buf_r, probe_r), kv_val_r);
                        end else if (probe_n_r + 32'd1 == new_cap_r) begin
                            `CA_FAULT;
                        end else begin
                            probe_w   = (probe_r + 32'd1) & (new_cap_r - 32'd1);
                            probe_r   <= probe_w;
                            probe_n_r <= probe_n_r + 32'd1;
                            `CA_ISSUE(1'b0, dslot_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                        end
                    end
                    DG_WK: begin
                        phase_r <= DG_WKT;
                        `CA_ISSUE(1'b1, dslot_addr(new_buf_r, probe_r) + 32'd16, kv_tag_r);
                    end
                    DG_WKT: begin
                        phase_r <= DG_WV;
                        `CA_ISSUE(1'b1, dslot_addr(new_buf_r, probe_r) + 32'd32, vv_val_r);
                    end
                    DG_WV: begin
                        phase_r <= DG_WVT;
                        `CA_ISSUE(1'b1, dslot_addr(new_buf_r, probe_r) + 32'd48, vv_tag_r);
                    end
                    DG_WVT: begin
                        if (ins_new_r) begin
                            phase_r <= DG_OA;
                            `CA_ISSUE(1'b1, elem_addr(order_new_r, order_len_r), nk_val_r);
                        end else if (idx_r + 32'd1 == slots_r) begin
                            phase_r <= DG_INS;
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= DG_RT;
                            `CA_ISSUE(1'b0, dslot_addr(old_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                        end
                    end
                    DG_OA: begin
                        phase_r <= DG_OAT;
                        `CA_ISSUE(1'b1, elem_addr(order_new_r, order_len_r) + 32'd16,
                              {124'b0, nk_tag_r});
                    end
                    DG_OAT: begin
                        phase_r <= DG_HH;
                        `CA_ISSUE(1'b1, obj_r,
                              {32'b0, new_cap_r, 32'b0, used_r + 32'd1});
                    end
                    DG_HH: begin
                        phase_r <= DG_HM;
                        `CA_ISSUE(1'b1, obj_r + 32'd16,
                              {32'b0, version_r + 32'd1, 32'b0, order_len_r + 32'd1});
                    end
                    DG_HM: begin
                        phase_r <= DG_HP;
                        `CA_ISSUE(1'b1, obj_r + 32'd32,
                              {32'b0, order_new_r, 32'b0, new_buf_r});
                    end
                    DG_HP: begin
                        `CA_OK(new_end_r);
                    end

                    SG_H0: begin
                        used_r  <= rdata_i[31:0];
                        slots_r <= rdata_i[95:64];
                        phase_r <= SG_H1;
                        `CA_ISSUE(1'b0, obj_r + 32'd16, 128'd0);
                    end
                    SG_H1: begin
                        old_buf_r <= rdata_i[31:0];
                        phase_r   <= SG_PLAN;
                    end
                    SG_Z: begin
                        if (idx_r + 32'd1 == new_cap_r) begin
                            if (slots_r == 32'd0) begin
                                phase_r <= SG_INS;
                            end else begin
                                idx_r   <= 32'd0;
                                phase_r <= SG_RT;
                                `CA_ISSUE(1'b0, elem_addr(old_buf_r, 32'd0) + 32'd16, 128'd0);
                            end
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= SG_Z;
                            `CA_ISSUE(1'b1, elem_addr(new_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                        end
                    end
                    SG_RT: begin
                        if (ca_skip_slot(rdata_i)) begin
                            if (idx_r + 32'd1 == slots_r) begin
                                phase_r <= SG_INS;
                            end else begin
                                idx_r   <= idx_r + 32'd1;
                                `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                            end
                        end else begin
                            kv_tag_r <= rdata_i;
                            phase_r  <= SG_RV;
                            `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r), 128'd0);
                        end
                    end
                    SG_RV: begin
                        kv_val_r  <= rdata_i;
                        probe_w   = ca_hash_idx(kv_tag_r[3:0], rdata_i, new_cap_r);
                        probe_r   <= probe_w;
                        probe_n_r <= 32'd0;
                        ins_new_r <= 1'b0;
                        phase_r   <= SG_PR;
                        `CA_ISSUE(1'b0, elem_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                    end
                    SG_PR: begin
                        if (pycore_dict_slot_empty(rdata_i)) begin
                            phase_r <= SG_WV;
                            `CA_ISSUE(1'b1, elem_addr(new_buf_r, probe_r), kv_val_r);
                        end else if (probe_n_r + 32'd1 == new_cap_r) begin
                            `CA_FAULT;
                        end else begin
                            probe_w   = (probe_r + 32'd1) & (new_cap_r - 32'd1);
                            probe_r   <= probe_w;
                            probe_n_r <= probe_n_r + 32'd1;
                            `CA_ISSUE(1'b0, elem_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                        end
                    end
                    SG_WV: begin
                        phase_r <= SG_WT;
                        `CA_ISSUE(1'b1, elem_addr(new_buf_r, probe_r) + 32'd16, kv_tag_r);
                    end
                    SG_WT: begin
                        if (ins_new_r) begin
                            phase_r <= SG_HH;
                            `CA_ISSUE(1'b1, obj_r,
                                  {32'b0, new_cap_r, 32'b0, used_r + 32'd1});
                        end else if (idx_r + 32'd1 == slots_r) begin
                            phase_r <= SG_INS;
                        end else begin
                            idx_r   <= idx_r + 32'd1;
                            phase_r <= SG_RT;
                            `CA_ISSUE(1'b0, elem_addr(old_buf_r, idx_r + 32'd1) + 32'd16, 128'd0);
                        end
                    end
                    SG_HH: begin
                        phase_r <= SG_HP;
                        `CA_ISSUE(1'b1, obj_r + 32'd16, {96'b0, new_buf_r});
                    end
                    SG_HP: begin
                        `CA_OK(new_end_r);
                    end
                    default: begin
                        `CA_FAULT;
                    end
                endcase
            end else if (!busy_r && !req_r && !dr_valid_r) begin
                unique case (phase_r)
                    PH_IDLE: begin
                        if (cmd_valid_i) begin
                            obj_r <= cmd_a_i[31:0];
                            unique case (cmd_op_i)
                                PY_CA_L_APPEND: begin
                                    elem_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                                    elem_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                                    phase_r    <= PH_HDR;
                                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                                end
                                PY_CA_L_EXTEND: begin
                                    src_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                                    src_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                                    phase_r   <= LE_HDR;
                                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                                end
                                PY_CA_L_DEL: begin
                                    del_idx_r <= cmd_b_i[31:0];
                                    phase_r   <= LD_HDR;
                                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                                end
                                PY_CA_D_GROW: begin
                                    nk_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                                    nk_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                                    nv_tag_r <= cmd_c_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                                    nv_val_r <= cmd_c_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                                    phase_r  <= DG_H0;
                                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                                end
                                PY_CA_S_GROW: begin
                                    nk_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                                    nk_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                                    phase_r  <= SG_H0;
                                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                                end
                                default: begin
                                    `CA_FAULT;
                                end
                            endcase
                        end
                    end
                    LE_PLAN: begin
                        sum  = {1'b0, len_r} + {1'b0, src_len_r};
                        need = sum[31:0];
                        if (sum[32]) begin
                            `CA_FAULT;
                        end else if (cap_r >= need) begin
                            inplace_r <= 1'b1;
                            new_cap_r <= cap_r;
                            new_buf_r <= old_buf_r;
                            if (src_len_r == 32'd0) begin
                                phase_r <= LE_HH;
                                `CA_ISSUE(1'b1, obj_r, {32'b0, cap_r, 32'b0, need});
                            end else begin
                                copy_src_r <= 1'b1;
                                idx_r      <= 32'd0;
                                phase_r    <= LE_CV;
                                `CA_ISSUE(1'b0, elem_addr(src_buf_r, 32'd0), 128'd0);
                            end
                        end else begin
                            ncap = ca_ext_cap(cap_r, need);
                            nend = cmd_heap_ptr_i + (ncap << 5);
                            inplace_r <= 1'b0;
                            new_cap_r <= ncap;
                            new_buf_r <= cmd_heap_ptr_i;
                            new_end_r <= nend;
                            if ((ncap < need) || (nend < cmd_heap_ptr_i)) begin
                                `CA_FAULT;
                            end else if (nend > cmd_heap_limit_i) begin
                                `CA_SHORT(nend - cmd_heap_ptr_i);
                            end else if (len_r != 32'd0) begin
                                copy_src_r <= 1'b0;
                                idx_r      <= 32'd0;
                                phase_r    <= LE_CV;
                                `CA_ISSUE(1'b0, elem_addr(old_buf_r, 32'd0), 128'd0);
                            end else if (src_len_r != 32'd0) begin
                                copy_src_r <= 1'b1;
                                idx_r      <= 32'd0;
                                phase_r    <= LE_CV;
                                `CA_ISSUE(1'b0, elem_addr(src_buf_r, 32'd0), 128'd0);
                            end else begin
                                phase_r <= LE_HH;
                                `CA_ISSUE(1'b1, obj_r, {32'b0, ncap, 32'b0, need});
                            end
                        end
                    end
                    LD_PLAN: begin
                        if (del_idx_r >= len_r) begin
                            `CA_FAULT;
                        end else if (del_idx_r + 32'd1 == len_r) begin
                            phase_r <= LD_HH;
                            `CA_ISSUE(1'b1, obj_r,
                                  {32'b0, cap_r, 32'b0, len_r - 32'd1});
                        end else begin
                            idx_r   <= del_idx_r;
                            phase_r <= LD_RV;
                            `CA_ISSUE(1'b0, elem_addr(old_buf_r, del_idx_r + 32'd1), 128'd0);
                        end
                    end
                    DG_PLAN: begin
                        ncap   = ca_grow_slots(used_r, slots_r);
                        ord_b  = ncap << 5;
                        tbase  = cmd_heap_ptr_i + ord_b;
                        tend   = tbase + (ncap << 6);
                        new_cap_r   <= ncap;
                        order_new_r <= cmd_heap_ptr_i;
                        new_buf_r   <= tbase;
                        new_end_r   <= tend;
                        if ((ncap < 32'd8) || (tbase < cmd_heap_ptr_i) || (tend < tbase)) begin
                            `CA_FAULT;
                        end else if (tend > cmd_heap_limit_i) begin
                            `CA_SHORT(tend - cmd_heap_ptr_i);
                        end else if (order_len_r != 32'd0) begin
                            idx_r   <= 32'd0;
                            phase_r <= DG_OR;
                            `CA_ISSUE(1'b0, elem_addr(order_ptr_r, 32'd0), 128'd0);
                        end else begin
                            idx_r   <= 32'd0;
                            phase_r <= DG_Z;
                            `CA_ISSUE(1'b1, dslot_addr(tbase, 32'd0) + 32'd16, 128'd0);
                        end
                    end
                    DG_INS: begin
                        kv_val_r  <= nk_val_r;
                        kv_tag_r  <= pycore_dict_key_tag_word(nk_tag_r, nk_val_r);
                        vv_val_r  <= nv_val_r;
                        vv_tag_r  <= {124'b0, nv_tag_r};
                        probe_w   = ca_hash_idx(nk_tag_r, nk_val_r, new_cap_r);
                        probe_r   <= probe_w;
                        probe_n_r <= 32'd0;
                        ins_new_r <= 1'b1;
                        phase_r   <= DG_PR;
                        `CA_ISSUE(1'b0, dslot_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                    end
                    SG_PLAN: begin
                        ncap = ca_grow_slots(used_r, slots_r);
                        nend = cmd_heap_ptr_i + (ncap << 5);
                        new_cap_r <= ncap;
                        new_buf_r <= cmd_heap_ptr_i;
                        new_end_r <= nend;
                        if ((ncap < 32'd8) || (nend < cmd_heap_ptr_i)) begin
                            `CA_FAULT;
                        end else if (nend > cmd_heap_limit_i) begin
                            `CA_SHORT(nend - cmd_heap_ptr_i);
                        end else begin
                            idx_r   <= 32'd0;
                            phase_r <= SG_Z;
                            `CA_ISSUE(1'b1, elem_addr(cmd_heap_ptr_i, 32'd0) + 32'd16, 128'd0);
                        end
                    end
                    SG_INS: begin
                        kv_val_r  <= nk_val_r;
                        kv_tag_r  <= pycore_dict_key_tag_word(nk_tag_r, nk_val_r);
                        probe_w   = ca_hash_idx(nk_tag_r, nk_val_r, new_cap_r);
                        probe_r   <= probe_w;
                        probe_n_r <= 32'd0;
                        ins_new_r <= 1'b1;
                        phase_r   <= SG_PR;
                        `CA_ISSUE(1'b0, elem_addr(new_buf_r, probe_w) + 32'd16, 128'd0);
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule

`undef CA_ISSUE
`undef CA_OK
`undef CA_SHORT
`undef CA_FAULT
