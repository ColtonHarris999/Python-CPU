`include "pycore_defs.svh"

module pycore_regfile #(
    parameter int RF_DEPTH = 96,
    parameter int VAL_WIDTH = PYCORE_VAL_WIDTH,
    parameter int TAG_WIDTH = PYCORE_TAG_WIDTH,
    parameter int LOCAL_COUNT = 32,
    parameter int STACK_BASE = 32
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [$clog2(RF_DEPTH)-1:0]  rs1_addr,
    input  logic [$clog2(RF_DEPTH)-1:0]  rs2_addr,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs1,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rs2,
    // Extra read port used by the core to fetch a slot's value for spilling.
    input  logic [$clog2(RF_DEPTH)-1:0]  rx_addr,
    output logic [TAG_WIDTH+VAL_WIDTH-1:0] rx,
    input  logic                         rd_we,
    input  logic [$clog2(RF_DEPTH)-1:0]  rd_addr,
    input  logic [TAG_WIDTH+VAL_WIDTH-1:0] rd,
    input  logic                         set_locals_base,
    input  logic [$clog2(RF_DEPTH)-1:0]  new_locals_base,
    input  logic                         init_frame,
    input  logic                         push_stack,
    input  logic                         pop_stack,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_ptr,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base,
    output logic                         stack_fault
);

    localparam int ENTRY_WIDTH = TAG_WIDTH + VAL_WIDTH;
    localparam int ADDR_W = $clog2(RF_DEPTH);
    localparam int STACK_LAST = RF_DEPTH - 1;

    logic [ENTRY_WIDTH-1:0] rf [0:RF_DEPTH-1];
    logic [ADDR_W-1:0] tos_q;
    logic [ADDR_W-1:0] locals_base_q;
    logic stack_fault_q;

    function automatic logic [ENTRY_WIDTH-1:0] uninitialized_entry();
        begin
            uninitialized_entry = {PY_TAG_UNINIT, {VAL_WIDTH{1'b0}}};
        end
    endfunction

    assign rs1 = rf[rs1_addr];
    assign rs2 = rf[rs2_addr];
    assign rx  = rf[rx_addr];
    assign tos_ptr = tos_q;
    assign locals_base = locals_base_q;
    assign stack_fault = stack_fault_q ||
                         (tos_q < STACK_BASE[ADDR_W-1:0]) ||
                         (tos_q > STACK_LAST[ADDR_W-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int i;
            for (i = 0; i < RF_DEPTH; i++) begin
                rf[i] = uninitialized_entry();
            end
            tos_q <= STACK_BASE[ADDR_W-1:0];
            locals_base_q <= '0;
            stack_fault_q <= 1'b0;
        end else begin
            stack_fault_q <= 1'b0;

            if (set_locals_base) begin
                locals_base_q <= new_locals_base;
            end

            if (init_frame) begin
                int j;
                for (j = 0; j < LOCAL_COUNT; j++) begin
                    if ((new_locals_base + j) < RF_DEPTH) begin
                        rf[new_locals_base + j] = uninitialized_entry();
                    end else begin
                        stack_fault_q <= 1'b1;
                    end
                end
            end

            if (rd_we) begin
                rf[rd_addr] <= rd;
            end

            unique case ({push_stack, pop_stack})
                2'b10: begin
                    if (tos_q < STACK_LAST[ADDR_W-1:0]) begin
                        tos_q <= tos_q + 1'b1;
                    end else begin
                        stack_fault_q <= 1'b1;
                    end
                end
                2'b01: begin
                    if (tos_q > STACK_BASE[ADDR_W-1:0]) begin
                        tos_q <= tos_q - 1'b1;
                    end else begin
                        stack_fault_q <= 1'b1;
                    end
                end
                default: begin
                end
            endcase
        end
    end

endmodule
