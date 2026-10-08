`include "pycore_defs.svh"
`include "pycore_ca_defs.svh"

// Container accelerator, stage A0: one command, data-ready and
// container-ready in the same cycle. The core is frozen while the
// command runs, so this port is the only dmem master.
//
// PY_CA_L_APPEND grows a full list (new_cap = cap ? cap*2 : 4), copies
// the old buffer, appends the element, and publishes the new ob_item
// last. Nothing is written before the heap check, so a short heap
// abandons the command.
module pycore_ca (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    input  logic                          cmd_valid_i,
    output logic                          cmd_ready_o,
    input  logic [6:0]                    cmd_op_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_a_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] cmd_b_i,
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
    typedef enum logic [3:0] {
        PH_IDLE,
        PH_HDR,
        PH_ITEM,
        PH_CV,
        PH_WV,
        PH_CT,
        PH_WT,
        PH_AV,
        PH_AT,
        PH_HH,
        PH_HI,
        PH_DONE
    } ph_e;

    ph_e  phase_r;
    logic busy_r;
    logic req_r;

    logic [31:0] obj_r, old_buf_r, new_buf_r, new_end_r;
    logic [31:0] len_r, cap_r, new_cap_r, idx_r;
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
    // A0: container-ready is data-ready. Later stages split them.
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
        logic [31:0] len_w, cap_w, ncap, nend, need;
        if (!rst_n_i) begin
            phase_r    <= PH_IDLE;
            busy_r     <= 1'b0;
            req_r      <= 1'b0;
            we_r       <= 1'b0;
            addr_r     <= '0;
            wdata_r    <= '0;
            dr_valid_r <= 1'b0;
            dr_ok_r    <= 1'b0;
            dr_short_r <= 1'b0;
            dr_fault_r <= 1'b0;
            dr_heap_r  <= '0;
            dr_need_r  <= '0;
            obj_r      <= '0;
            old_buf_r  <= '0;
            new_buf_r  <= '0;
            new_end_r  <= '0;
            len_r      <= '0;
            cap_r      <= '0;
            new_cap_r  <= '0;
            idx_r      <= '0;
            hold_r     <= '0;
            elem_tag_r <= '0;
            elem_val_r <= '0;
        end else begin
            if (dr_valid_r && dr_ready_i) begin
                dr_valid_r <= 1'b0;
                dr_ok_r    <= 1'b0;
                dr_short_r <= 1'b0;
                dr_fault_r <= 1'b0;
            end
            if (req_r) begin
                // One-cycle request. The wait is busy_r with req low.
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
                    default: begin `CA_FAULT; end
                endcase
            end else if ((phase_r == PH_IDLE) && cmd_valid_i && !dr_valid_r) begin
                if (cmd_op_i != PY_CA_L_APPEND) begin
                    `CA_FAULT;
                end else begin
                    obj_r      <= cmd_a_i[31:0];
                    elem_tag_r <= cmd_b_i[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
                    elem_val_r <= cmd_b_i[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
                    phase_r    <= PH_HDR;
                    `CA_ISSUE(1'b0, cmd_a_i[31:0], 128'd0);
                end
            end
        end
    end
endmodule

`undef CA_ISSUE
`undef CA_OK
`undef CA_SHORT
`undef CA_FAULT
