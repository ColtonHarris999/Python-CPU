import pycore_types_pkg::*;

module pycore_top #(
    parameter int PROG_DEPTH = 512,
    parameter int CONST_DEPTH = 256,
    parameter string PROG_HEX = "programs/pycore_prog.hex",
    parameter string CONST_HEX = "programs/pycore_consts.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        trap_out,
    output logic [3:0]  trap_code,
    output logic [63:0] cycle_count,
    output logic        halted,
    output logic        ret_valid,
    output logic [1:0]  ret_tag,
    output logic [63:0] ret_value
);
    typedef enum logic [1:0] {
        ST_RUN = 2'd0,
        ST_WAIT_DIV = 2'd1,
        ST_HALT = 2'd2
    } state_t;

    localparam int RF_DEPTH = 96;
    localparam int LOCAL_BASE = 0;
    localparam int STACK_BASE = 32;
    localparam int STACK_DEPTH = 64;
    localparam int ENTRY_W = 66;

    logic [39:0] instr_mem [0:PROG_DEPTH-1];
    logic [1:0]  rf_tag [0:RF_DEPTH-1];
    logic [63:0] rf_val [0:RF_DEPTH-1];

    logic [31:0] pc;
    logic [31:0] ext_accum;
    logic [6:0]  tos_ptr;
    state_t      state;

    logic [7:0]  fetch_opcode;
    logic [31:0] fetch_arg;
    logic        fetch_is_ext;
    logic [31:0] fetch_ext_out;

    logic        dec_valid_opcode;
    logic        dec_load_const;
    logic        dec_load_fast;
    logic        dec_store_fast;
    logic        dec_pop_top;
    logic        dec_copy;
    logic        dec_swap;
    logic        dec_branch;
    logic        dec_return;
    logic        dec_call;
    logic        dec_unary;
    logic        dec_binary;
    logic        dec_compare;
    logic [5:0]  dec_alu_cmd;

    logic [ENTRY_W-1:0] const_entry;
    logic [ENTRY_W-1:0] tos_entry;
    logic [ENTRY_W-1:0] nos_entry;

    logic branch_take;
    logic [31:0] branch_target;
    logic branch_pop_tos;
    logic branch_trap;
    logic [3:0] branch_trap_code;

    logic               alu_start;
    logic [5:0]         alu_cmd;
    logic [ENTRY_W-1:0] alu_op_a;
    logic [ENTRY_W-1:0] alu_op_b;
    logic [ENTRY_W-1:0] alu_result;
    logic               alu_done;
    logic               alu_stall;
    logic               alu_trap;
    logic [3:0]         alu_trap_code;

    logic [5:0]         pending_alu_cmd;
    logic [ENTRY_W-1:0] pending_alu_a;
    logic [ENTRY_W-1:0] pending_alu_b;
    logic [31:0]        pending_next_pc;
    logic               pending_binary;

    logic stage_type_trap;
    logic stage_stack_fault;
    logic stage_div_zero;
    logic stage_illegal_opcode;
    logic stage_frame_fault;

    logic [31:0] trap_pc;
    logic [63:0] trap_tos_val;
    logic [1:0]  trap_tos_tag;

    function automatic logic [ENTRY_W-1:0] pack_entry(
        input logic [1:0] t,
        input logic [63:0] v
    );
        begin
            pack_entry = {t, v};
        end
    endfunction

    function automatic logic [6:0] stack_index(input logic [6:0] depth);
        begin
            stack_index = STACK_BASE + tos_ptr - 1'b1 - depth;
        end
    endfunction

    initial begin
        int i;
        $readmemh(PROG_HEX, instr_mem);
        for (i = 0; i < RF_DEPTH; i++) begin
            rf_tag[i] = TAG_UNINIT;
            rf_val[i] = 64'd0;
        end
    end

    always_comb begin
        if (tos_ptr > 0) begin
            tos_entry = pack_entry(rf_tag[stack_index(0)], rf_val[stack_index(0)]);
        end else begin
            tos_entry = pack_entry(TAG_UNINIT, 64'd0);
        end

        if (tos_ptr > 1) begin
            nos_entry = pack_entry(rf_tag[stack_index(1)], rf_val[stack_index(1)]);
        end else begin
            nos_entry = pack_entry(TAG_UNINIT, 64'd0);
        end
    end

    pycore_fetch u_fetch (
        .instr_word(instr_mem[pc]),
        .ext_accum_in(ext_accum),
        .opcode(fetch_opcode),
        .arg(fetch_arg),
        .is_extended_arg(fetch_is_ext),
        .ext_accum_out(fetch_ext_out)
    );

    pycore_decode u_decode (
        .opcode(fetch_opcode),
        .arg(fetch_arg),
        .valid_opcode(dec_valid_opcode),
        .is_load_const(dec_load_const),
        .is_load_fast(dec_load_fast),
        .is_store_fast(dec_store_fast),
        .is_pop_top(dec_pop_top),
        .is_copy(dec_copy),
        .is_swap(dec_swap),
        .is_branch(dec_branch),
        .is_return(dec_return),
        .is_call(dec_call),
        .is_unary(dec_unary),
        .is_binary(dec_binary),
        .is_compare(dec_compare),
        .alu_cmd(dec_alu_cmd)
    );

    pycore_const_table #(
        .CONST_DEPTH(CONST_DEPTH),
        .CONST_HEX(CONST_HEX)
    ) u_const (
        .idx(fetch_arg[$clog2(CONST_DEPTH)-1:0]),
        .entry(const_entry)
    );

    pycore_branch u_branch (
        .opcode(fetch_opcode),
        .arg(fetch_arg),
        .pc(pc),
        .tos_entry(tos_entry),
        .take_branch(branch_take),
        .branch_target(branch_target),
        .pop_tos(branch_pop_tos),
        .trap(branch_trap),
        .trap_code(branch_trap_code)
    );

    always_comb begin
        alu_start = 1'b0;
        alu_cmd = ALU_NOP;
        alu_op_a = nos_entry;
        alu_op_b = tos_entry;

        if (state == ST_WAIT_DIV) begin
            alu_cmd = pending_alu_cmd;
            alu_op_a = pending_alu_a;
            alu_op_b = pending_alu_b;
        end else if (state == ST_RUN && (dec_unary || dec_binary || dec_compare)) begin
            alu_start = 1'b1;
            alu_cmd = dec_alu_cmd;
            if (dec_unary) begin
                alu_op_a = tos_entry;
                alu_op_b = pack_entry(TAG_UNINIT, 64'd0);
            end
        end
    end

    pycore_alu u_alu (
        .clk(clk),
        .rst_n(rst_n),
        .start(alu_start),
        .cmd(alu_cmd),
        .op_a(alu_op_a),
        .op_b(alu_op_b),
        .result(alu_result),
        .done(alu_done),
        .stall(alu_stall),
        .trap(alu_trap),
        .trap_code(alu_trap_code)
    );

    pycore_trap u_trap (
        .clk(clk),
        .rst_n(rst_n),
        .clear_trap(1'b0),
        .trap_pc_in(pc),
        .trap_tos_in(tos_entry),
        .stage_type_trap(stage_type_trap),
        .stage_stack_fault(stage_stack_fault),
        .stage_div_zero(stage_div_zero),
        .stage_illegal_opcode(stage_illegal_opcode),
        .stage_frame_fault(stage_frame_fault),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .trap_pc(trap_pc),
        .trap_tos_val(trap_tos_val),
        .trap_tos_tag(trap_tos_tag)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        logic [31:0] next_pc;
        logic [6:0] idx;
        logic [6:0] idx2;
        logic [1:0] tmp_tag;
        logic [63:0] tmp_val;

        if (!rst_n) begin
            pc <= 32'd0;
            ext_accum <= 32'd0;
            tos_ptr <= 7'd0;
            state <= ST_RUN;
            cycle_count <= 64'd0;
            halted <= 1'b0;
            ret_valid <= 1'b0;
            ret_tag <= TAG_UNINIT;
            ret_value <= 64'd0;
            pending_alu_cmd <= ALU_NOP;
            pending_alu_a <= pack_entry(TAG_UNINIT, 64'd0);
            pending_alu_b <= pack_entry(TAG_UNINIT, 64'd0);
            pending_next_pc <= 32'd0;
            pending_binary <= 1'b0;

            stage_type_trap <= 1'b0;
            stage_stack_fault <= 1'b0;
            stage_div_zero <= 1'b0;
            stage_illegal_opcode <= 1'b0;
            stage_frame_fault <= 1'b0;
        end else begin
            ret_valid <= 1'b0;
            stage_type_trap <= 1'b0;
            stage_stack_fault <= 1'b0;
            stage_div_zero <= 1'b0;
            stage_illegal_opcode <= 1'b0;
            stage_frame_fault <= 1'b0;

            if (!trap_out && !halted) begin
                cycle_count <= cycle_count + 1'b1;

                unique case (state)
                    ST_WAIT_DIV: begin
                        if (alu_done) begin
                            if (alu_trap) begin
                                if (alu_trap_code == TRAP_DIV_ZERO) begin
                                    stage_div_zero <= 1'b1;
                                end else begin
                                    stage_type_trap <= 1'b1;
                                end
                                state <= ST_RUN;
                            end else begin
                                if (pending_binary) begin
                                    rf_tag[STACK_BASE + tos_ptr - 2] <= alu_result[65:64];
                                    rf_val[STACK_BASE + tos_ptr - 2] <= alu_result[63:0];
                                    tos_ptr <= tos_ptr - 1'b1;
                                end else begin
                                    rf_tag[STACK_BASE + tos_ptr - 1] <= alu_result[65:64];
                                    rf_val[STACK_BASE + tos_ptr - 1] <= alu_result[63:0];
                                end
                                pc <= pending_next_pc;
                                state <= ST_RUN;
                            end
                        end
                    end

                    ST_RUN: begin
                        next_pc = pc + 32'd1;
                        if (fetch_is_ext) begin
                            ext_accum <= fetch_ext_out;
                            pc <= next_pc;
                        end else if (!dec_valid_opcode) begin
                            stage_illegal_opcode <= 1'b1;
                        end else if (dec_load_const) begin
                            if (tos_ptr < STACK_DEPTH) begin
                                rf_tag[STACK_BASE + tos_ptr] <= const_entry[65:64];
                                rf_val[STACK_BASE + tos_ptr] <= const_entry[63:0];
                                tos_ptr <= tos_ptr + 1'b1;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_load_fast) begin
                            if (tos_ptr < STACK_DEPTH) begin
                                idx = LOCAL_BASE + fetch_arg[6:0];
                                rf_tag[STACK_BASE + tos_ptr] <= rf_tag[idx];
                                rf_val[STACK_BASE + tos_ptr] <= rf_val[idx];
                                tos_ptr <= tos_ptr + 1'b1;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_store_fast) begin
                            if (tos_ptr > 0) begin
                                idx = LOCAL_BASE + fetch_arg[6:0];
                                rf_tag[idx] <= tos_entry[65:64];
                                rf_val[idx] <= tos_entry[63:0];
                                tos_ptr <= tos_ptr - 1'b1;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_pop_top) begin
                            if (tos_ptr > 0) begin
                                tos_ptr <= tos_ptr - 1'b1;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_copy) begin
                            if ((tos_ptr > fetch_arg[6:0]) && (tos_ptr < STACK_DEPTH)) begin
                                idx = stack_index(fetch_arg[6:0]);
                                rf_tag[STACK_BASE + tos_ptr] <= rf_tag[idx];
                                rf_val[STACK_BASE + tos_ptr] <= rf_val[idx];
                                tos_ptr <= tos_ptr + 1'b1;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_swap) begin
                            if (tos_ptr > fetch_arg[6:0]) begin
                                idx = stack_index(0);
                                idx2 = stack_index(fetch_arg[6:0]);
                                tmp_tag = rf_tag[idx];
                                tmp_val = rf_val[idx];
                                rf_tag[idx] <= rf_tag[idx2];
                                rf_val[idx] <= rf_val[idx2];
                                rf_tag[idx2] <= tmp_tag;
                                rf_val[idx2] <= tmp_val;
                                pc <= next_pc;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_branch) begin
                            if (branch_trap) begin
                                stage_type_trap <= 1'b1;
                            end else begin
                                if (branch_pop_tos) begin
                                    if (tos_ptr > 0) begin
                                        tos_ptr <= tos_ptr - 1'b1;
                                    end else begin
                                        stage_stack_fault <= 1'b1;
                                    end
                                end
                                if (branch_take) begin
                                    pc <= branch_target;
                                end else begin
                                    pc <= next_pc;
                                end
                            end
                        end else if (dec_call) begin
                            stage_type_trap <= 1'b1;
                        end else if (dec_return) begin
                            if (tos_ptr > 0) begin
                                ret_valid <= 1'b1;
                                ret_tag <= tos_entry[65:64];
                                ret_value <= tos_entry[63:0];
                                tos_ptr <= tos_ptr - 1'b1;
                                halted <= 1'b1;
                                state <= ST_HALT;
                            end else begin
                                stage_stack_fault <= 1'b1;
                            end
                        end else if (dec_unary || dec_binary || dec_compare) begin
                            if (dec_unary && (tos_ptr == 0)) begin
                                stage_stack_fault <= 1'b1;
                            end else if ((dec_binary || dec_compare) && (tos_ptr < 2)) begin
                                stage_stack_fault <= 1'b1;
                            end else if (alu_trap) begin
                                if (alu_trap_code == TRAP_DIV_ZERO) begin
                                    stage_div_zero <= 1'b1;
                                end else begin
                                    stage_type_trap <= 1'b1;
                                end
                            end else if (alu_stall || !alu_done) begin
                                pending_alu_cmd <= dec_alu_cmd;
                                pending_alu_a <= dec_unary ? tos_entry : nos_entry;
                                pending_alu_b <= dec_unary ? pack_entry(TAG_UNINIT, 64'd0) : tos_entry;
                                pending_next_pc <= next_pc;
                                pending_binary <= !dec_unary;
                                state <= ST_WAIT_DIV;
                            end else begin
                                if (dec_unary) begin
                                    rf_tag[STACK_BASE + tos_ptr - 1] <= alu_result[65:64];
                                    rf_val[STACK_BASE + tos_ptr - 1] <= alu_result[63:0];
                                end else begin
                                    rf_tag[STACK_BASE + tos_ptr - 2] <= alu_result[65:64];
                                    rf_val[STACK_BASE + tos_ptr - 2] <= alu_result[63:0];
                                    tos_ptr <= tos_ptr - 1'b1;
                                end
                                pc <= next_pc;
                            end
                        end else begin
                            pc <= next_pc;
                        end

                        ext_accum <= 32'd0;
                    end

                    default: begin
                    end
                endcase
            end
        end
    end
endmodule
