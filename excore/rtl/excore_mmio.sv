// excore_mmio: the excore's MMIO peripheral — mailbox (read side), result
// (write side), and the shared-dmem slot port that bridges the 32-bit hart
// to 128-bit pycore dmem slots. Documented in excore/docs/mmio_map.md;
// offsets below must match that file exactly.
//
// This module owns no core logic: it is a pure memory-mapped register bank
// plus the slot-port bridge FSM. In Phase B a testbench drives the mailbox_*
// inputs directly with canned trap messages; in Phase C those inputs are
// driven by trap_mailbox.sv / pycore_system on a real trap_req handshake,
// and result_* outputs feed the trap_res handshake back to pycore.
module excore_mmio #(
    parameter int MAX_TRAP_ENTRIES = 4,
    parameter int MAX_RES_ENTRIES  = 2
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // ---- CPU-facing slave port (excore_cpu is the master) --------------
    input  logic         cpu_req_i,
    input  logic         cpu_we_i,
    input  logic [31:0]  cpu_addr_i,   // full address; only [7:0] decoded
    input  logic [31:0]  cpu_wdata_i,
    output logic         cpu_ack_o,
    output logic [31:0]  cpu_rdata_o,

    // ---- Mailbox (read side) — populated externally --------------------
    input  logic         mb_trap_pending_i,
    input  logic [4:0]   mb_trap_code_i,
    input  logic [31:0]  mb_pc_i,
    input  logic [7:0]   mb_opcode_i,
    input  logic [31:0]  mb_arg_i,
    input  logic [31:0]  mb_heap_ptr_i,
    input  logic [2:0]   mb_entry_count_i,
    input  logic [131:0] mb_entries_i [0:MAX_TRAP_ENTRIES-1],

    // ---- Result (write side) — consumed externally ----------------------
    output logic         res_go_o,       // one-cycle pulse on RES_GO write
    output logic [3:0]   res_code_o,
    output logic [4:0]   res_fatal_code_o,
    output logic [2:0]   res_pop_count_o,
    output logic [1:0]   res_push_count_o,
    output logic [31:0]  res_heap_ptr_o,
    output logic [131:0] res_entries_o [0:MAX_RES_ENTRIES-1],

    // ---- Shared-dmem slot port (master; wired to a real pycore_mem_bank) -
    output logic         sp_req_o,
    output logic         sp_we_o,
    output logic [31:0]  sp_addr_o,
    output logic [127:0] sp_wdata_o,
    input  logic          sp_ack_i,
    input  logic [127:0]  sp_rdata_i,
    input  logic          sp_fault_i
);

    // -------------------------------------------------------------------
    // Register offsets (byte, relative to the 0xF000_0000 MMIO base —
    // excore_cpu's address decode already stripped the base; only the low
    // byte matters here). Mirrors excore/docs/mmio_map.md exactly.
    // -------------------------------------------------------------------
    localparam logic [7:0] OFF_MB_STATUS      = 8'h00;
    localparam logic [7:0] OFF_MB_TRAP_CODE   = 8'h04;
    localparam logic [7:0] OFF_MB_PC          = 8'h08;
    localparam logic [7:0] OFF_MB_INSTR_LO    = 8'h0C;
    localparam logic [7:0] OFF_MB_INSTR_HI    = 8'h10;
    localparam logic [7:0] OFF_MB_HEAP_PTR    = 8'h14;
    localparam logic [7:0] OFF_MB_ENTRY_COUNT = 8'h18;
    localparam logic [7:0] OFF_MB_ENTRY_BASE  = 8'h20;
    localparam int          MB_ENTRY_STRIDE   = 8'h14; // 5 words * 4 bytes

    localparam logic [7:0] OFF_RES_CODE       = 8'h80;
    localparam logic [7:0] OFF_RES_POP_COUNT  = 8'h84;
    localparam logic [7:0] OFF_RES_PUSH_COUNT = 8'h88;
    localparam logic [7:0] OFF_RES_HEAP_PTR   = 8'h8C;
    localparam logic [7:0] OFF_RES_ENTRY_BASE = 8'h90;
    localparam int          RES_ENTRY_STRIDE  = 8'h14;
    localparam logic [7:0] OFF_RES_GO         = 8'hC0;

    localparam logic [7:0] OFF_SP_ADDR    = 8'hD0;
    localparam logic [7:0] OFF_SP_CTRL    = 8'hD4;
    localparam logic [7:0] OFF_SP_STATUS  = 8'hD8;
    localparam logic [7:0] OFF_SP_DATA0   = 8'hE0;
    localparam logic [7:0] OFF_SP_DATA1   = 8'hE4;
    localparam logic [7:0] OFF_SP_DATA2   = 8'hE8;
    localparam logic [7:0] OFF_SP_DATA3   = 8'hEC;
    // Write-only console byte (BI_PRINT). Captured by TB; RTL discards.
    localparam logic [7:0] OFF_CONSOLE_TX = 8'hF0;

    logic [7:0] off;
    assign off = cpu_addr_i[7:0];

    // -------------------------------------------------------------------
    // Result staging registers (written by firmware SW before RES_GO).
    // -------------------------------------------------------------------
    logic [3:0]   res_code_r;
    logic [4:0]   res_fatal_code_r;
    logic [2:0]   res_pop_count_r;
    logic [1:0]   res_push_count_r;
    logic [31:0]  res_heap_ptr_r;
    logic [131:0] res_entries_r [0:MAX_RES_ENTRIES-1];

    assign res_code_o        = res_code_r;
    assign res_fatal_code_o  = res_fatal_code_r;
    assign res_pop_count_o   = res_pop_count_r;
    assign res_push_count_o  = res_push_count_r;
    assign res_heap_ptr_o    = res_heap_ptr_r;
    assign res_entries_o     = res_entries_r;

    // result_accepted (MB_STATUS bit1): set the cycle RES_GO commits;
    // cleared whenever the mailbox is not presenting a pending trap (a
    // fresh trap_pending assertion always starts from a clean slate).
    logic result_accepted_r;

    // -------------------------------------------------------------------
    // Slot-port bridge FSM: one read/write transaction per go strobe.
    // -------------------------------------------------------------------
    logic [31:0]  sp_addr_r;
    logic [127:0] sp_data_r;   // staging window for SP_DATA0..3
    logic         sp_busy_r;
    logic         sp_req_sent_r;  // req_o must pulse exactly one cycle —
                                   // pycore_mem_bank samples req_i on every
                                   // edge and acks unconditionally one cycle
                                   // later, so holding req_o high across
                                   // multiple cycles would issue duplicate
                                   // transactions (mirrors pycore_mem_stage's
                                   // req_sent_r discipline for PTR ops).
    logic         sp_fault_sticky_r;
    logic         sp_pending_we_r;

    logic sp_read_go_w, sp_write_go_w;
    // A write of SP_CTRL from the CPU with bit0/bit1 set is the strobe;
    // decoded combinationally from the current bus cycle.
    assign sp_read_go_w  = cpu_req_i && cpu_we_i && (off == OFF_SP_CTRL) && cpu_wdata_i[0];
    assign sp_write_go_w = cpu_req_i && cpu_we_i && (off == OFF_SP_CTRL) && cpu_wdata_i[1];

    assign sp_req_o   = sp_busy_r && !sp_req_sent_r;
    assign sp_we_o    = sp_pending_we_r;
    assign sp_addr_o  = sp_addr_r;
    assign sp_wdata_o = sp_data_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            sp_busy_r         <= 1'b0;
            sp_req_sent_r     <= 1'b0;
            sp_pending_we_r   <= 1'b0;
            sp_fault_sticky_r <= 1'b0;
            sp_addr_r         <= 32'h0;
        end else begin
            if (sp_busy_r) begin
                if (sp_req_sent_r && sp_ack_i) begin
                    sp_busy_r         <= 1'b0;
                    sp_req_sent_r     <= 1'b0;
                    sp_fault_sticky_r <= sp_fault_i;
                end else if (!sp_req_sent_r) begin
                    sp_req_sent_r <= 1'b1;
                end
            end else if (sp_read_go_w || sp_write_go_w) begin
                sp_busy_r         <= 1'b1;
                sp_pending_we_r   <= sp_write_go_w;
                sp_fault_sticky_r <= 1'b0; // cleared at the start of a new go
            end
        end
    end

    // SP_DATA capture on a completed read; data staging for writes is
    // updated by ordinary register writes below (SP_DATA0..3).
    logic sp_read_capture;
    assign sp_read_capture = sp_busy_r && sp_req_sent_r && sp_ack_i && !sp_pending_we_r;

    // -------------------------------------------------------------------
    // Register writes (address decode).
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            res_code_r        <= 4'h0;
            res_fatal_code_r  <= 5'h0;
            res_pop_count_r   <= 3'h0;
            res_push_count_r  <= 2'h0;
            res_heap_ptr_r    <= 32'h0;
            res_go_o          <= 1'b0;
            result_accepted_r <= 1'b0;
            sp_data_r         <= 128'h0;
            for (int i = 0; i < MAX_RES_ENTRIES; i++) res_entries_r[i] <= 132'h0;
        end else begin
            res_go_o <= 1'b0; // one-cycle pulse; cleared by default every cycle

            if (sp_read_capture) begin
                sp_data_r <= sp_rdata_i;
            end

            if (!mb_trap_pending_i) begin
                result_accepted_r <= 1'b0;
            end

            if (cpu_req_i && cpu_we_i) begin
                unique case (off)
                    OFF_RES_CODE: begin
                        res_code_r       <= cpu_wdata_i[3:0];
                        res_fatal_code_r <= cpu_wdata_i[8:4];
                    end
                    OFF_RES_POP_COUNT:  res_pop_count_r  <= cpu_wdata_i[2:0];
                    OFF_RES_PUSH_COUNT: res_push_count_r <= cpu_wdata_i[1:0];
                    OFF_RES_HEAP_PTR:   res_heap_ptr_r   <= cpu_wdata_i;
                    OFF_RES_GO: begin
                        if (cpu_wdata_i[0]) begin
                            res_go_o          <= 1'b1;
                            result_accepted_r <= 1'b1;
                        end
                    end
                    OFF_SP_ADDR: sp_addr_r <= cpu_wdata_i;
                    OFF_SP_DATA0: sp_data_r[31:0]    <= cpu_wdata_i;
                    OFF_SP_DATA1: sp_data_r[63:32]   <= cpu_wdata_i;
                    OFF_SP_DATA2: sp_data_r[95:64]   <= cpu_wdata_i;
                    OFF_SP_DATA3: sp_data_r[127:96]  <= cpu_wdata_i;
                    default: ; // OFF_SP_CTRL handled by the go strobe above;
                                // MB_* offsets are read-only from the CPU.
                endcase

                // RES_ENTRY[i] writes (5-word stride, VAL0..3 then TAG).
                for (int i = 0; i < MAX_RES_ENTRIES; i++) begin
                    if (off == OFF_RES_ENTRY_BASE + i * RES_ENTRY_STRIDE) begin
                        res_entries_r[i][31:0] <= cpu_wdata_i;
                    end else if (off == OFF_RES_ENTRY_BASE + i * RES_ENTRY_STRIDE + 4) begin
                        res_entries_r[i][63:32] <= cpu_wdata_i;
                    end else if (off == OFF_RES_ENTRY_BASE + i * RES_ENTRY_STRIDE + 8) begin
                        res_entries_r[i][95:64] <= cpu_wdata_i;
                    end else if (off == OFF_RES_ENTRY_BASE + i * RES_ENTRY_STRIDE + 12) begin
                        res_entries_r[i][127:96] <= cpu_wdata_i;
                    end else if (off == OFF_RES_ENTRY_BASE + i * RES_ENTRY_STRIDE + 16) begin
                        res_entries_r[i][131:128] <= cpu_wdata_i[3:0];
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------
    // Register reads (combinational; 1-cycle ack registered below).
    // -------------------------------------------------------------------
    logic [31:0] rdata_comb;
    always_comb begin
        rdata_comb = 32'h0;

        if (off == OFF_MB_STATUS) begin
            rdata_comb = {30'b0, result_accepted_r, mb_trap_pending_i};
        end else if (off == OFF_MB_TRAP_CODE) begin
            rdata_comb = {27'b0, mb_trap_code_i};
        end else if (off == OFF_MB_PC) begin
            rdata_comb = mb_pc_i;
        end else if (off == OFF_MB_INSTR_LO) begin
            rdata_comb = {mb_arg_i[23:0], mb_opcode_i};
        end else if (off == OFF_MB_INSTR_HI) begin
            rdata_comb = {24'b0, mb_arg_i[31:24]};
        end else if (off == OFF_MB_HEAP_PTR) begin
            rdata_comb = mb_heap_ptr_i;
        end else if (off == OFF_MB_ENTRY_COUNT) begin
            rdata_comb = {29'b0, mb_entry_count_i};
        end else if (off == OFF_RES_CODE) begin
            rdata_comb = {23'b0, res_fatal_code_r, res_code_r};
        end else if (off == OFF_RES_POP_COUNT) begin
            rdata_comb = {29'b0, res_pop_count_r};
        end else if (off == OFF_RES_PUSH_COUNT) begin
            rdata_comb = {30'b0, res_push_count_r};
        end else if (off == OFF_RES_HEAP_PTR) begin
            rdata_comb = res_heap_ptr_r;
        end else if (off == OFF_SP_STATUS) begin
            rdata_comb = {30'b0, sp_fault_sticky_r, sp_busy_r};
        end else if (off == OFF_SP_DATA0) begin
            rdata_comb = sp_data_r[31:0];
        end else if (off == OFF_SP_DATA1) begin
            rdata_comb = sp_data_r[63:32];
        end else if (off == OFF_SP_DATA2) begin
            rdata_comb = sp_data_r[95:64];
        end else if (off == OFF_SP_DATA3) begin
            rdata_comb = sp_data_r[127:96];
        end else begin
            // MB_ENTRY[i] read (5-word stride).
            for (int i = 0; i < MAX_TRAP_ENTRIES; i++) begin
                if (off == OFF_MB_ENTRY_BASE + i * MB_ENTRY_STRIDE) begin
                    rdata_comb = mb_entries_i[i][31:0];
                end else if (off == OFF_MB_ENTRY_BASE + i * MB_ENTRY_STRIDE + 4) begin
                    rdata_comb = mb_entries_i[i][63:32];
                end else if (off == OFF_MB_ENTRY_BASE + i * MB_ENTRY_STRIDE + 8) begin
                    rdata_comb = mb_entries_i[i][95:64];
                end else if (off == OFF_MB_ENTRY_BASE + i * MB_ENTRY_STRIDE + 12) begin
                    rdata_comb = mb_entries_i[i][127:96];
                end else if (off == OFF_MB_ENTRY_BASE + i * MB_ENTRY_STRIDE + 16) begin
                    rdata_comb = {28'b0, mb_entries_i[i][131:128]};
                end
            end
        end
    end

    logic ack_r;
    logic [31:0] rdata_r;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            ack_r   <= 1'b0;
            rdata_r <= 32'h0;
        end else begin
            ack_r   <= cpu_req_i;
            rdata_r <= rdata_comb;
        end
    end
    assign cpu_ack_o   = ack_r;
    assign cpu_rdata_o = rdata_r;

endmodule
