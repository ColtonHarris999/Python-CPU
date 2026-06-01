import pycore_types_pkg::*;

module pycore_regfile #(
    parameter int RF_DEPTH = 96,
    parameter int LOCAL_DEPTH = 32,
    parameter int STACK_BASE = 32,
    parameter int STACK_DEPTH = 64,
    parameter int VAL_WIDTH = 64,
    parameter int TAG_WIDTH = 2
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic [6:0]                    rs1_addr,
    input  logic [6:0]                    rs2_addr,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs1_entry,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs2_entry,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] tos_entry,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] nos_entry,
    output logic [6:0]                    tos_ptr,

    input  logic                          wr_en,
    input  logic [6:0]                    wr_addr,
    input  logic [TAG_WIDTH+VAL_WIDTH-1:0] wr_entry,

    input  logic                          local_write_en,
    input  logic [6:0]                    local_addr,
    input  logic [TAG_WIDTH+VAL_WIDTH-1:0] local_entry,

    input  logic                          push_en,
    input  logic [TAG_WIDTH+VAL_WIDTH-1:0] push_entry,
    input  logic                          pop_en,
    input  logic [1:0]                    pop_count,
    input  logic                          copy_en,
    input  logic [6:0]                    copy_depth,
    input  logic                          swap_en,
    input  logic [6:0]                    swap_depth,

    output logic                          stack_fault
);
    logic [TAG_WIDTH-1:0] tag_mem [0:RF_DEPTH-1];
    logic [VAL_WIDTH-1:0] val_mem [0:RF_DEPTH-1];

    function automatic logic [6:0] stack_idx_from_top(input logic [6:0] depth);
        begin
            stack_idx_from_top = STACK_BASE + tos_ptr - 1'b1 - depth;
        end
    endfunction

    always_comb begin
        rs1_entry = {tag_mem[rs1_addr], val_mem[rs1_addr]};
        rs2_entry = {tag_mem[rs2_addr], val_mem[rs2_addr]};
        if (tos_ptr > 0) begin
            tos_entry = {tag_mem[stack_idx_from_top(0)], val_mem[stack_idx_from_top(0)]};
        end else begin
            tos_entry = {TAG_UNINIT, 64'd0};
        end

        if (tos_ptr > 1) begin
            nos_entry = {tag_mem[stack_idx_from_top(1)], val_mem[stack_idx_from_top(1)]};
        end else begin
            nos_entry = {TAG_UNINIT, 64'd0};
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        int i;
        logic [6:0] idx_a;
        logic [6:0] idx_b;
        logic [TAG_WIDTH-1:0] tmp_tag;
        logic [VAL_WIDTH-1:0] tmp_val;

        if (!rst_n) begin
            tos_ptr <= 0;
            stack_fault <= 1'b0;
            for (i = 0; i < RF_DEPTH; i++) begin
                tag_mem[i] <= TAG_UNINIT;
                val_mem[i] <= '0;
            end
        end else begin
            stack_fault <= 1'b0;

            if (wr_en && (wr_addr < RF_DEPTH)) begin
                tag_mem[wr_addr] <= wr_entry[TAG_WIDTH+VAL_WIDTH-1:VAL_WIDTH];
                val_mem[wr_addr] <= wr_entry[VAL_WIDTH-1:0];
            end

            if (local_write_en && (local_addr < RF_DEPTH)) begin
                tag_mem[local_addr] <= local_entry[TAG_WIDTH+VAL_WIDTH-1:VAL_WIDTH];
                val_mem[local_addr] <= local_entry[VAL_WIDTH-1:0];
            end

            if (copy_en) begin
                if ((tos_ptr > copy_depth) && (tos_ptr < STACK_DEPTH)) begin
                    idx_a = stack_idx_from_top(copy_depth);
                    tag_mem[STACK_BASE + tos_ptr] <= tag_mem[idx_a];
                    val_mem[STACK_BASE + tos_ptr] <= val_mem[idx_a];
                    tos_ptr <= tos_ptr + 1'b1;
                end else begin
                    stack_fault <= 1'b1;
                end
            end

            if (swap_en) begin
                if (tos_ptr > swap_depth) begin
                    idx_a = stack_idx_from_top(0);
                    idx_b = stack_idx_from_top(swap_depth);
                    tmp_tag = tag_mem[idx_a];
                    tmp_val = val_mem[idx_a];
                    tag_mem[idx_a] <= tag_mem[idx_b];
                    val_mem[idx_a] <= val_mem[idx_b];
                    tag_mem[idx_b] <= tmp_tag;
                    val_mem[idx_b] <= tmp_val;
                end else begin
                    stack_fault <= 1'b1;
                end
            end

            if (push_en) begin
                if (tos_ptr < STACK_DEPTH) begin
                    tag_mem[STACK_BASE + tos_ptr] <= push_entry[TAG_WIDTH+VAL_WIDTH-1:VAL_WIDTH];
                    val_mem[STACK_BASE + tos_ptr] <= push_entry[VAL_WIDTH-1:0];
                    tos_ptr <= tos_ptr + 1'b1;
                end else begin
                    stack_fault <= 1'b1;
                end
            end

            if (pop_en) begin
                if (tos_ptr >= pop_count) begin
                    tos_ptr <= tos_ptr - pop_count;
                end else begin
                    tos_ptr <= 0;
                    stack_fault <= 1'b1;
                end
            end
        end
    end
endmodule
