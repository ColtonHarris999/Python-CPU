`include "pycore_defs.svh"

// MEM pipeline stage. Operates on the EX/MEM register contents presented by the
// core and produces the writeback entry consumed by the MEM/WB register.
//
//   - Pass-through ops (NONE/LOAD_FAST/STORE_FAST): forward the EX result entry
//     to writeback.
//   - LOAD_CONST: forward the inline_const_i assembled by the fetch unit directly
//     to writeback. No separate ROM lookup is required because the constant value
//     was already embedded in the instruction stream and reconstructed by fetch.
//   - LOAD_PTR / STORE_PTR: drive a real dmem transaction over the req/ack
//     handshake, stalling the pipeline until the access completes; a load tags
//     the result INT.
//
// Memory faults (misaligned, address out of the 32-bit window, or a bank
// out-of-range fault) raise a trap rather than corrupting state.
module pycore_mem_stage #(
    parameter int ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int DMEM_DATA_W = PYCORE_DMEM_DATA_WIDTH
) (
    input  logic                          clk_i,
    input  logic                          rst_n_i,
    input  logic                          valid_i,
    input  logic [2:0]                    mem_op_i,
    input  logic                          rd_we_in_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] alu_entry_i,    // store data / pass value
    input  logic [PYCORE_ENTRY_WIDTH-1:0] addr_entry_i,   // PTR base address
    // Inline constant assembled by the fetch unit for LOAD_CONST instructions.
    input  logic [PYCORE_ENTRY_WIDTH-1:0] inline_const_i,
    // dmem master port
    output logic                          dmem_req_o,
    output logic                          dmem_we_o,
    output logic [ADDR_WIDTH-1:0]         dmem_addr_o,
    output logic [DMEM_DATA_W-1:0]        dmem_wdata_o,
    input  logic                          dmem_ack_i,
    input  logic [DMEM_DATA_W-1:0]        dmem_rdata_i,
    input  logic                          dmem_fault_i,
    // writeback outputs
    output logic                          wb_we_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] wb_entry_o,
    output logic                          mem_stall_o,
    output logic                          mem_trap_o,
    output logic [3:0]                    mem_trap_code_o
);

    logic                          is_load_ptr;
    logic                          is_store_ptr;
    logic                          is_ptr_op;
    logic [PYCORE_VAL_WIDTH-1:0]   addr_val;
    logic                          misaligned;
    logic                          oob_upper;
    logic                          pre_trap;
    logic                          req_sent_r;
    logic                          access_done;

    assign is_load_ptr  = valid_i && (mem_op_i == PY_MEM_LOAD_PTR);
    assign is_store_ptr = valid_i && (mem_op_i == PY_MEM_STORE_PTR);
    assign is_ptr_op    = is_load_ptr || is_store_ptr;

    assign addr_val   = pycore_get_val(addr_entry_i);
    // 128-bit access is 16-byte aligned in v1.
    assign misaligned = is_ptr_op && (|addr_val[3:0]);
    // Only the low ADDR_WIDTH bits are decoded onto the bus.
    assign oob_upper  = is_ptr_op && (|addr_val[PYCORE_VAL_WIDTH-1:ADDR_WIDTH]);
    assign pre_trap   = misaligned || oob_upper;

    // Handshake: assert req until it is captured, expect ack the next cycle.
    assign dmem_req_o   = is_ptr_op && !pre_trap && !req_sent_r;
    assign dmem_we_o    = is_store_ptr;
    assign dmem_addr_o  = addr_val[ADDR_WIDTH-1:0];
    assign dmem_wdata_o = pycore_get_val(alu_entry_i);

    assign access_done = req_sent_r && dmem_ack_i;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            req_sent_r <= 1'b0;
        end else if (access_done) begin
            req_sent_r <= 1'b0;
        end else if (dmem_req_o) begin
            req_sent_r <= 1'b1;
        end
    end

    always_comb begin
        // Default: pass-through writeback for non-memory and FAST ops.
        wb_entry_o      = alu_entry_i;
        wb_we_o         = valid_i && rd_we_in_i;
        mem_stall_o     = 1'b0;
        mem_trap_o      = 1'b0;
        mem_trap_code_o = PY_TRAP_NONE;

        if (valid_i && mem_op_i == PY_MEM_LOAD_CONST) begin
            // The constant was assembled inline by the fetch unit; forward it.
            wb_entry_o = inline_const_i;
            wb_we_o    = rd_we_in_i;
        end else if (is_ptr_op) begin
            if (pre_trap) begin
                wb_we_o         = 1'b0;
                mem_trap_o      = 1'b1;
                mem_trap_code_o = misaligned ? PY_TRAP_ADDR_ALIGN : PY_TRAP_MEM_FAULT;
            end else if (!access_done) begin
                // Transaction in flight: freeze the pipeline behind us.
                wb_we_o     = 1'b0;
                mem_stall_o = 1'b1;
            end else begin
                // Access completed this cycle.
                if (dmem_fault_i) begin
                    wb_we_o         = 1'b0;
                    mem_trap_o      = 1'b1;
                    mem_trap_code_o = PY_TRAP_MEM_FAULT;
                end else if (is_load_ptr) begin
                    wb_entry_o = pycore_make_entry(PY_TAG_INT, dmem_rdata_i);
                    wb_we_o    = rd_we_in_i;
                end else begin
                    wb_we_o = 1'b0;  // store completed, nothing to write back
                end
            end
        end
    end

endmodule
