// excore_cpu: exception-core hart wrapper around the vendored singlecore
// RISC-V multicycle CPU (excore/rtl/singlecore/riscv_multicycle.sv).
//
// External contract is unchanged from the previous purpose-built RV32I
// wrapper: private firmware IMEM (FW_HEX), private 1 KB scratch RAM at
// 0x0000_0000, MMIO window at 0xF000_0000 routed to excore_mmio, and a
// sticky fault_o backstop for out-of-range data accesses. Firmware
// (list_grow.s) and mailbox / slot-port semantics are identical.
//
// Internally this module:
//   1. Instantiates riscv_multicycle (active-high reset, memory_io buses).
//   2. Serves instruction fetches from a private IMEM word array (default 8 KB).
//   3. Decodes data_mem_req into scratch vs MMIO vs OOB, matching the
//      registered one-cycle memory_io response style of singlecore's
//      memory32 so the multicycle stage machine (fetch→…→writeback) makes
//      forward progress.

`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "riscv_multicycle.sv"

module excore_cpu #(
    parameter string FW_HEX        = "",
    parameter int    IMEM_WORDS    = 2048,  // 8 KB / 4 bytes per word (list+dict handlers)
    parameter int    SCRATCH_WORDS = 256    // 1 KB / 4 bytes per word
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // External MMIO bus master (32-bit; excore_mmio is the slave).
    output logic        mmio_req_o,
    output logic        mmio_we_o,
    output logic [31:0] mmio_addr_o,
    output logic [31:0] mmio_wdata_o,
    input  logic         mmio_ack_i,
    input  logic [31:0]  mmio_rdata_i,

    // Hardware correctness backstop: sticky once raised.
    output logic         fault_o,
    output logic [31:0]  fault_pc_o
);

    localparam int IMEM_AW = $clog2(IMEM_WORDS);
    localparam int SCRATCH_AW = $clog2(SCRATCH_WORDS);
    localparam logic [31:0] SCRATCH_LIMIT = SCRATCH_WORDS * 4;
    localparam logic [31:0] MMIO_BASE = 32'hF000_0000;

    // Active-high reset for the vendored singlecore hart.
    logic reset;
    assign reset = ~rst_n_i;

    // -------------------------------------------------------------------
    // Private instruction memory (Harvard: fetch never touches data bus).
    // Preloaded from FW_HEX via $readmemh — same discipline as before.
    // -------------------------------------------------------------------
    logic [31:0] imem [0:IMEM_WORDS-1];
    initial begin
        int i;
        for (i = 0; i < IMEM_WORDS; i++) imem[i] = 32'h0000_0013; // NOP
        if (FW_HEX != "") $readmemh(FW_HEX, imem);
    end

    // Private scratch RAM (1 KB @ data address 0x0).
    logic [31:0] scratch [0:SCRATCH_WORDS-1];
    initial begin
        int i;
        for (i = 0; i < SCRATCH_WORDS; i++) scratch[i] = 32'h0;
    end

    // -------------------------------------------------------------------
    // Vendored multicycle hart
    // -------------------------------------------------------------------
    memory_io_req inst_mem_req;
    memory_io_rsp inst_mem_rsp;
    memory_io_req data_mem_req;
    memory_io_rsp data_mem_rsp;

    riscv_multicycle core (
        .clk(clk_i),
        .reset(reset),
        .reset_pc(32'h0),
        .inst_mem_req(inst_mem_req),
        .inst_mem_rsp(inst_mem_rsp),
        .data_mem_req(data_mem_req),
        .data_mem_rsp(data_mem_rsp)
    );

    logic        mmio_pending_r;
    logic [31:0] mmio_addr_r;

    logic data_is_scratch, data_is_mmio, data_is_oob;
    logic data_is_write, data_is_read;
    assign data_is_scratch = (data_mem_req.addr < SCRATCH_LIMIT);
    assign data_is_mmio    = (data_mem_req.addr[31:28] == MMIO_BASE[31:28]);
    assign data_is_oob     = !data_is_scratch && !data_is_mmio;
    assign data_is_write   = is_any_byte(data_mem_req.do_write);
    assign data_is_read    = is_any_byte(data_mem_req.do_read);

    logic inst_oob;
    assign inst_oob = inst_mem_req.valid && is_any_byte(inst_mem_req.do_read) &&
                      ((inst_mem_req.addr >> 2) >= IMEM_WORDS);

    // -------------------------------------------------------------------
    // Instruction + data memory slaves and fault backstop (one always_ff
    // so fault_o has a single driver).
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (reset) begin
            inst_mem_rsp   <= memory_io_no_rsp;
            data_mem_rsp   <= memory_io_no_rsp;
            mmio_req_o     <= 1'b0;
            mmio_we_o      <= 1'b0;
            mmio_addr_o    <= 32'h0;
            mmio_wdata_o   <= 32'h0;
            mmio_pending_r <= 1'b0;
            mmio_addr_r    <= 32'h0;
            fault_o        <= 1'b0;
            fault_pc_o     <= 32'h0;
        end else begin
            // Defaults each cycle.
            inst_mem_rsp <= memory_io_no_rsp;
            data_mem_rsp <= memory_io_no_rsp;
            mmio_req_o   <= 1'b0;

            // ---- Instruction fetch ------------------------------------
            if (inst_mem_req.valid && is_any_byte(inst_mem_req.do_read)) begin
                inst_mem_rsp.valid    <= 1'b1;
                inst_mem_rsp.ready    <= 1'b1;
                inst_mem_rsp.user_tag <= inst_mem_req.user_tag;
                inst_mem_rsp.addr     <= inst_mem_req.addr;
                if (!inst_oob) begin
                    inst_mem_rsp.data <= imem[inst_mem_req.addr[IMEM_AW+1:2]];
                end else begin
                    inst_mem_rsp.data <= 32'h0000_0013;
                    fault_o           <= 1'b1;
                    fault_pc_o        <= inst_mem_req.addr;
                end
            end

            // ---- Data: complete outstanding MMIO, else new request ----
            if (mmio_pending_r) begin
                if (mmio_ack_i) begin
                    data_mem_rsp.valid    <= 1'b1;
                    data_mem_rsp.ready    <= 1'b1;
                    data_mem_rsp.user_tag <= {`user_tag_size{1'b0}};
                    data_mem_rsp.addr     <= mmio_addr_r;
                    data_mem_rsp.data     <= mmio_rdata_i;
                    mmio_pending_r        <= 1'b0;
                end else begin
                    data_mem_rsp.ready <= 1'b1;
                end
            end else if (data_mem_req.valid && (data_is_read || data_is_write)) begin
                if (data_is_scratch) begin
                    data_mem_rsp.valid    <= 1'b1;
                    data_mem_rsp.ready    <= 1'b1;
                    data_mem_rsp.user_tag <= data_mem_req.user_tag;
                    data_mem_rsp.addr     <= data_mem_req.addr;
                    if (data_is_write) begin
                        if (data_mem_req.do_write[0])
                            scratch[data_mem_req.addr[SCRATCH_AW+1:2]][7:0]   <= data_mem_req.data[7:0];
                        if (data_mem_req.do_write[1])
                            scratch[data_mem_req.addr[SCRATCH_AW+1:2]][15:8]  <= data_mem_req.data[15:8];
                        if (data_mem_req.do_write[2])
                            scratch[data_mem_req.addr[SCRATCH_AW+1:2]][23:16] <= data_mem_req.data[23:16];
                        if (data_mem_req.do_write[3])
                            scratch[data_mem_req.addr[SCRATCH_AW+1:2]][31:24] <= data_mem_req.data[31:24];
                        data_mem_rsp.data <= data_mem_req.data;
                    end else begin
                        data_mem_rsp.data <= scratch[data_mem_req.addr[SCRATCH_AW+1:2]];
                    end
                end else if (data_is_mmio) begin
                    mmio_req_o     <= 1'b1;
                    mmio_we_o      <= data_is_write;
                    mmio_addr_o    <= data_mem_req.addr;
                    mmio_wdata_o   <= data_mem_req.data;
                    mmio_addr_r    <= data_mem_req.addr;
                    mmio_pending_r <= 1'b1;
                    data_mem_rsp.ready <= 1'b1;
                end else begin
                    data_mem_rsp.valid    <= 1'b1;
                    data_mem_rsp.ready    <= 1'b1;
                    data_mem_rsp.user_tag <= data_mem_req.user_tag;
                    data_mem_rsp.addr     <= data_mem_req.addr;
                    data_mem_rsp.data     <= 32'h0;
                    fault_o              <= 1'b1;
                    fault_pc_o           <= data_mem_req.addr;
                end
            end
        end
    end

endmodule
