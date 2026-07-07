`include "pycore_defs.svh"

// MEM pipeline stage. Operates on the EX/MEM register contents presented by the
// core and produces the writeback entry consumed by the MEM/WB register.
//
//   - Pass-through ops (NONE/LOAD_FAST/STORE_FAST): forward the EX result entry
//     to writeback.
//   - LOAD_CONST: forward the inline_const assembled by the fetch unit directly
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
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          valid,
    input  logic [2:0]                    mem_op,
    input  logic                          rd_we_in,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] alu_entry,    // store data / pass value
    input  logic [PYCORE_ENTRY_WIDTH-1:0] addr_entry,   // PTR base address
    // Inline constant assembled by the fetch unit for LOAD_CONST instructions.
    input  logic [PYCORE_ENTRY_WIDTH-1:0] inline_const,
    // dmem master port
    output logic                          dmem_req,
    output logic                          dmem_we,
    output logic [ADDR_WIDTH-1:0]         dmem_addr,
    output logic [DMEM_DATA_W-1:0]        dmem_wdata,
    input  logic                          dmem_ack,
    input  logic [DMEM_DATA_W-1:0]        dmem_rdata,
    input  logic                          dmem_fault,
    // writeback outputs
    output logic                          wb_we,
    output logic [PYCORE_ENTRY_WIDTH-1:0] wb_entry,
    output logic                          mem_stall,
    output logic                          mem_trap,
    output logic [3:0]                    mem_trap_code
);

    logic                          is_load_ptr;
    logic                          is_store_ptr;
    logic                          is_ptr_op;
    logic [PYCORE_VAL_WIDTH-1:0]   addr_val;
    logic                          misaligned;
    logic                          oob_upper;
    logic                          pre_trap;
    logic                          req_sent_q;
    logic                          access_done;

    assign is_load_ptr  = valid && (mem_op == PY_MEM_LOAD_PTR);
    assign is_store_ptr = valid && (mem_op == PY_MEM_STORE_PTR);
    assign is_ptr_op    = is_load_ptr || is_store_ptr;

    assign addr_val   = pycore_get_val(addr_entry);
    // 128-bit access is 16-byte aligned in v1.
    assign misaligned = is_ptr_op && (|addr_val[3:0]);
    // Only the low ADDR_WIDTH bits are decoded onto the bus.
    assign oob_upper  = is_ptr_op && (|addr_val[PYCORE_VAL_WIDTH-1:ADDR_WIDTH]);
    assign pre_trap   = misaligned || oob_upper;

    // Handshake: assert req until it is captured, expect ack the next cycle.
    assign dmem_req   = is_ptr_op && !pre_trap && !req_sent_q;
    assign dmem_we    = is_store_ptr;
    assign dmem_addr  = addr_val[ADDR_WIDTH-1:0];
    assign dmem_wdata = pycore_get_val(alu_entry);

    assign access_done = req_sent_q && dmem_ack;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_sent_q <= 1'b0;
        end else if (access_done) begin
            req_sent_q <= 1'b0;
        end else if (dmem_req) begin
            req_sent_q <= 1'b1;
        end
    end

    always_comb begin
        // Default: pass-through writeback for non-memory and FAST ops.
        wb_entry      = alu_entry;
        wb_we         = valid && rd_we_in;
        mem_stall     = 1'b0;
        mem_trap      = 1'b0;
        mem_trap_code = PY_TRAP_NONE;

        if (valid && mem_op == PY_MEM_LOAD_CONST) begin
            // The constant was assembled inline by the fetch unit; forward it.
            wb_entry = inline_const;
            wb_we    = rd_we_in;
        end else if (is_ptr_op) begin
            if (pre_trap) begin
                wb_we         = 1'b0;
                mem_trap      = 1'b1;
                mem_trap_code = misaligned ? PY_TRAP_ADDR_ALIGN : PY_TRAP_MEM_FAULT;
            end else if (!access_done) begin
                // Transaction in flight: freeze the pipeline behind us.
                wb_we     = 1'b0;
                mem_stall = 1'b1;
            end else begin
                // Access completed this cycle.
                if (dmem_fault) begin
                    wb_we         = 1'b0;
                    mem_trap      = 1'b1;
                    mem_trap_code = PY_TRAP_MEM_FAULT;
                end else if (is_load_ptr) begin
                    wb_entry = pycore_make_entry(PY_TAG_INT, dmem_rdata);
                    wb_we    = rd_we_in;
                end else begin
                    wb_we = 1'b0;  // store completed, nothing to write back
                end
            end
        end
    end

endmodule
