`include "pycore_defs.svh"

module pycore_regfile #(
    parameter int RF_DEPTH = PYCORE_RF_DEPTH,
    parameter int VAL_WIDTH = PYCORE_VAL_WIDTH,
    parameter int TAG_WIDTH = PYCORE_TAG_WIDTH,
    parameter int RF_INIT_CHUNK = PYCORE_RF_INIT_CHUNK
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
    // Clear RF slots [new_locals_base + init_from .. new_locals_base + init_until)
    // to UNINIT, wrapping at RF_DEPTH. Filled parameter slots stay intact.
    input  logic [$clog2(RF_DEPTH)-1:0]  init_from_i,
    input  logic [$clog2(RF_DEPTH)-1:0]  init_until_i,
    input  logic                         push_stack_i,
    input  logic                         pop_stack_i,
    output logic [$clog2(RF_DEPTH)-1:0]  tos_ptr_o,
    output logic [$clog2(RF_DEPTH)-1:0]  locals_base_o,
    output logic                         stack_fault_o,
    output logic [$clog2(RF_DEPTH):0]    resident_o
);

    localparam int ENTRY_WIDTH = TAG_WIDTH + VAL_WIDTH;
    localparam int ADDR_W = $clog2(RF_DEPTH);
    localparam int OCC_W = ADDR_W + 1;

    logic [ENTRY_WIDTH-1:0] rf [0:RF_DEPTH-1];
    logic [ADDR_W-1:0] tos_r;
    logic [ADDR_W-1:0] locals_base_r;
    logic [OCC_W-1:0] resident_r;
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
    assign resident_o = resident_r;
    assign stack_fault_o = stack_fault_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            int i;
            for (i = 0; i < RF_DEPTH; i++) begin
                rf[i] = uninitialized_entry();
            end
            tos_r <= '0;
            locals_base_r <= '0;
            resident_r <= '0;
            stack_fault_r <= 1'b0;
        end else begin
            stack_fault_r <= 1'b0;

            if (set_locals_base_i) begin
                locals_base_r <= new_locals_base_i;
            end

            if (init_frame_i) begin
                int j;
                // Only wipe unfilled slots (temps / unbound locals). Parameter
                // slots [0, init_from) already hold args / defaults / *args.
                // Addresses wrap: the window is a ring over all RF_DEPTH entries.
                for (j = 0; j < RF_INIT_CHUNK; j++) begin
                    if ((int'(init_from_i) + j) < int'(init_until_i)) begin
                        rf[new_locals_base_i + init_from_i + ADDR_W'(j)]
                            = uninitialized_entry();
                    end
                end
            end

            if (rd_we_i) begin
                rf[rd_addr_i] <= rd_i;
            end

            unique case ({push_stack_i, pop_stack_i})
                2'b10: begin
                    if (resident_r < OCC_W'(RF_DEPTH)) begin
                        tos_r <= tos_r + 1'b1;
                        resident_r <= resident_r + 1'b1;
                    end else begin
                        stack_fault_r <= 1'b1;
                    end
                end
                2'b01: begin
                    if (resident_r != '0) begin
                        tos_r <= tos_r - 1'b1;
                        resident_r <= resident_r - 1'b1;
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
