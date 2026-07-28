// trap_mailbox: the pycore <-> excore trap transport (Phase C).
//
// Wide parallel valid/ready handshake in each direction — the message
// does NOT live in shared dmem, because dmem ownership is exactly what is
// being transferred (see pycore_excore_system.sv's memory-ownership grant
// mux). Wide parallel buses are acceptable for now; single-beat ->
// multi-beat serialization is future ASIC work (see architecture.md).
//
// This module is a pure adapter between two different handshake styles:
//   - pycore's trap_req/trap_res are proper valid/ready handshakes.
//   - excore_mmio's mailbox is level-held (mb_trap_pending_o stays
//     asserted until the firmware reports a result via RES_GO) and its
//     result is a one-cycle pulse (res_go_i).
//
// Three states: idle (ready for a new request) -> waiting on the excore's
// result -> presenting that result to pycore until trap_res_ready_i acks
// it.  "Owner flips to EXCORE when a trap_req handshake completes, back
// to PYCORE when the trap_res handshake completes" (memory-ownership
// protocol) means exactly: idle->wait_res is the trap_req handshake;
// res_valid->idle is the trap_res handshake.
module trap_mailbox #(
    parameter int MAX_TRAP_ENTRIES = 3,
    parameter int MAX_RES_ENTRIES  = 2
) (
    input  logic         clk_i,
    input  logic         rst_n_i,

    // ---- pycore side (trap_req: pycore is the requester) ----------------
    input  logic          trap_req_valid_i,
    output logic          trap_req_ready_o,
    input  logic [3:0]    trap_req_code_i,
    input  logic [31:0]   trap_req_pc_i,
    input  logic [39:0]   trap_req_instr_i,
    input  logic [31:0]   trap_req_heap_ptr_i,
    input  logic [2:0]    trap_req_entry_count_i,
    input  logic [131:0]  trap_req_entries_i [0:MAX_TRAP_ENTRIES-1],

    // ---- pycore side (trap_res: pycore is the consumer) ------------------
    output logic          trap_res_valid_o,
    input  logic           trap_res_ready_i,
    output logic [3:0]     trap_res_code_o,
    output logic [3:0]     trap_res_fatal_code_o,
    output logic [2:0]     trap_res_pop_count_o,
    output logic [1:0]     trap_res_push_count_o,
    output logic [31:0]    trap_res_heap_ptr_o,
    output logic [131:0]   trap_res_entries_o [0:MAX_RES_ENTRIES-1],

    // ---- excore side (mailbox, read side of excore_mmio) -----------------
    output logic          mb_trap_pending_o,
    output logic [3:0]    mb_trap_code_o,
    output logic [31:0]   mb_pc_o,
    output logic [7:0]    mb_opcode_o,
    output logic [31:0]   mb_arg_o,
    output logic [31:0]   mb_heap_ptr_o,
    output logic [2:0]    mb_entry_count_o,
    output logic [131:0]  mb_entries_o [0:MAX_TRAP_ENTRIES-1],

    // ---- excore side (result, write side of excore_mmio) ------------------
    input  logic          res_go_i,
    input  logic [3:0]    ex_res_code_i,
    input  logic [3:0]    ex_res_fatal_code_i,
    input  logic [2:0]    ex_res_pop_count_i,
    input  logic [1:0]    ex_res_push_count_i,
    input  logic [31:0]   ex_res_heap_ptr_i,
    input  logic [131:0]  ex_res_entries_i [0:MAX_RES_ENTRIES-1]
);

    localparam logic [1:0] S_IDLE     = 2'd0;
    localparam logic [1:0] S_WAIT_RES = 2'd1;
    localparam logic [1:0] S_RES_VALID = 2'd2;

    logic [1:0] state_r;

    // Latched request (presented to excore_mmio's mailbox inputs while
    // mb_trap_pending_o is asserted).
    logic [3:0]   mb_trap_code_r;
    logic [31:0]  mb_pc_r;
    logic [7:0]   mb_opcode_r;
    logic [31:0]  mb_arg_r;
    logic [31:0]  mb_heap_ptr_r;
    logic [2:0]   mb_entry_count_r;
    logic [131:0] mb_entries_r [0:MAX_TRAP_ENTRIES-1];

    // Latched result (presented to pycore while trap_res_valid_o is
    // asserted).
    logic [3:0]   res_code_r;
    logic [3:0]   res_fatal_code_r;
    logic [2:0]   res_pop_count_r;
    logic [1:0]   res_push_count_r;
    logic [31:0]  res_heap_ptr_r;
    logic [131:0] res_entries_r [0:MAX_RES_ENTRIES-1];

    assign trap_req_ready_o = (state_r == S_IDLE);
    assign trap_res_valid_o = (state_r == S_RES_VALID);

    assign mb_trap_pending_o = (state_r == S_WAIT_RES);
    assign mb_trap_code_o    = mb_trap_code_r;
    assign mb_pc_o           = mb_pc_r;
    assign mb_opcode_o       = mb_opcode_r;
    assign mb_arg_o          = mb_arg_r;
    assign mb_heap_ptr_o     = mb_heap_ptr_r;
    assign mb_entry_count_o  = mb_entry_count_r;
    assign mb_entries_o      = mb_entries_r;

    assign trap_res_code_o        = res_code_r;
    assign trap_res_fatal_code_o  = res_fatal_code_r;
    assign trap_res_pop_count_o   = res_pop_count_r;
    assign trap_res_push_count_o  = res_push_count_r;
    assign trap_res_heap_ptr_o    = res_heap_ptr_r;
    assign trap_res_entries_o     = res_entries_r;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r          <= S_IDLE;
            mb_trap_code_r   <= 4'h0;
            mb_pc_r          <= 32'h0;
            mb_opcode_r      <= 8'h0;
            mb_arg_r         <= 32'h0;
            mb_heap_ptr_r    <= 32'h0;
            mb_entry_count_r <= 3'h0;
            res_code_r       <= 4'h0;
            res_fatal_code_r <= 4'h0;
            res_pop_count_r  <= 3'h0;
            res_push_count_r <= 2'h0;
            res_heap_ptr_r   <= 32'h0;
            for (int i = 0; i < MAX_TRAP_ENTRIES; i++) mb_entries_r[i] <= 132'h0;
            for (int i = 0; i < MAX_RES_ENTRIES; i++)  res_entries_r[i] <= 132'h0;
        end else begin
            unique case (state_r)
                S_IDLE: begin
                    if (trap_req_valid_i) begin
                        mb_trap_code_r   <= trap_req_code_i;
                        mb_pc_r          <= trap_req_pc_i;
                        mb_opcode_r      <= trap_req_instr_i[7:0];
                        mb_arg_r         <= trap_req_instr_i[39:8];
                        mb_heap_ptr_r    <= trap_req_heap_ptr_i;
                        mb_entry_count_r <= trap_req_entry_count_i;
                        for (int i = 0; i < MAX_TRAP_ENTRIES; i++) begin
                            mb_entries_r[i] <= trap_req_entries_i[i];
                        end
                        state_r <= S_WAIT_RES;
                    end
                end

                S_WAIT_RES: begin
                    if (res_go_i) begin
                        res_code_r       <= ex_res_code_i;
                        res_fatal_code_r <= ex_res_fatal_code_i;
                        res_pop_count_r  <= ex_res_pop_count_i;
                        res_push_count_r <= ex_res_push_count_i;
                        res_heap_ptr_r   <= ex_res_heap_ptr_i;
                        for (int i = 0; i < MAX_RES_ENTRIES; i++) begin
                            res_entries_r[i] <= ex_res_entries_i[i];
                        end
                        state_r <= S_RES_VALID;
                    end
                end

                S_RES_VALID: begin
                    if (trap_res_ready_i) state_r <= S_IDLE;
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end

endmodule
