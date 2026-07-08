`include "pycore_defs.svh"

module pycore_regfile #(
    parameter int RF_DEPTH = 96,
    parameter int VAL_WIDTH = PYCORE_VAL_WIDTH,
    parameter int TAG_WIDTH = PYCORE_TAG_WIDTH,
    parameter int LOCAL_COUNT = 32,
    parameter int STACK_BASE = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_n_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  rs1_addr_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  rs2_addr_i,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs1_o,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs2_o,
    input  logic                         rd_we_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  rd_addr_i,
    input  logic [TAG_WIDTH+VAL_WIDTH-1:0] rd_i,
    input  logic                         set_locals_base_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base_i,
    input  logic                         init_frame_i,
    input  logic                         push_stack_i,
    input  logic                         pop_stack_i,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_ptr_o,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_o,
    output logic                         stack_fault_o
);

    localparam int ENTRY_WIDTH = TAG_WIDTH + VAL_WIDTH;
    localparam int ADDR_W = $clog2(RF_DEPTH);
    localparam int STACK_LAST = RF_DEPTH - 1;

    logic [ENTRY_WIDTH-1:0] rf [0:RF_DEPTH-1];
    logic [ADDR_W-1:0] tos_r;
    logic [ADDR_W-1:0] locals_base_r;
    logic stack_fault_r;

    function automatic logic [ENTRY_WIDTH-1:0] uninitialized_entry();
        begin
            uninitialized_entry = {PY_TAG_UNINIT, {VAL_WIDTH{1'b0}}};
        end
    endfunction

    assign rs1_o = rf[rs1_addr_i];
    assign rs2_o = rf[rs2_addr_i];
    assign tos_ptr_o = tos_r;
    assign locals_base_o = locals_base_r;
    assign stack_fault_o = stack_fault_r ||
                         (tos_r < STACK_BASE[ADDR_W-1:0]) ||
                         (tos_r > STACK_LAST[ADDR_W-1:0]);

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            int i;
            for (i = 0; i < RF_DEPTH; i++) begin
                rf[i] = uninitialized_entry();
            end
            tos_r <= STACK_BASE[ADDR_W-1:0];
            locals_base_r <= '0;
            stack_fault_r <= 1'b0;
        end else begin
            stack_fault_r <= 1'b0;

            if (set_locals_base_i) begin
                locals_base_r <= new_locals_base_i;
            end

            if (init_frame_i) begin
                int j;
                for (j = 0; j < LOCAL_COUNT; j++) begin
                    if ((new_locals_base_i + j) < RF_DEPTH) begin
                        rf[new_locals_base_i + j] = uninitialized_entry();
                    end else begin
                        stack_fault_r <= 1'b1;
                    end
                end
            end

            if (rd_we_i) begin
                rf[rd_addr_i] <= rd_i;
            end

            unique case ({push_stack_i, pop_stack_i})
                2'b10: begin
                    if (tos_r < STACK_LAST[ADDR_W-1:0]) begin
                        tos_r <= tos_r + 1'b1;
                    end else begin
                        stack_fault_r <= 1'b1;
                    end
                end
                2'b01: begin
                    if (tos_r > STACK_BASE[ADDR_W-1:0]) begin
                        tos_r <= tos_r - 1'b1;
                    end else begin
                        stack_fault_r <= 1'b1;
                    end
                end
                default: begin
                end
            endcase
        end
    end

endmodule
