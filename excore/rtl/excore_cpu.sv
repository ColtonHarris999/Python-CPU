// excore_cpu: minimal RV32I hart for the excore (exception core).
//
// Multi-cycle, no pipeline — this core's job is correctness and small area
// (dict rehash / GC / emulating unimplemented opcodes is software territory;
// an FSM-per-trap-class would just relocate RTL complexity without
// generality — see docs/architecture.md). Every instruction takes 2 cycles
// (fetch, execute) except loads/stores that target the external MMIO bus,
// which take a 3rd cycle waiting for the bus ack.
//
// Supported subset (anything else raises fault_o and parks permanently —
// firmware itself never emits anything outside this subset; fault_o exists
// purely as a hardware correctness backstop):
//   LUI, AUIPC, JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU, LW, SW,
//   ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
//   ADD, SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA.
// No LB/LH (all data accesses are word-aligned; unaligned LW/SW fault), no
// CSRs, no FENCE, no ECALL. "Halt/park" is a firmware jump-to-self, not a
// hardware halt state — fault_o is the only true hardware halt.
//
// Memory map (data address space; separate from the private instruction
// address space used for fetch):
//   0x0000_0000 - 0x0000_03FF : private scratch RAM (1 KB, word-addressed)
//   0xF000_0000 - ...         : external MMIO bus (routed to excore_mmio)
//   anything else             : fault_o (out-of-range data access)
module excore_cpu #(
    parameter string FW_HEX       = "",
    parameter int    IMEM_WORDS   = 1024,  // 4 KB / 4 bytes per word
    parameter int    SCRATCH_WORDS = 256   // 1 KB / 4 bytes per word
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

    // Hardware correctness backstop: sticky once raised, core parks.
    output logic         fault_o,
    output logic [31:0]  fault_pc_o
);

    localparam int IMEM_AW = $clog2(IMEM_WORDS);
    localparam int SCRATCH_AW = $clog2(SCRATCH_WORDS);
    localparam logic [31:0] SCRATCH_LIMIT = SCRATCH_WORDS * 4;
    localparam logic [31:0] MMIO_BASE = 32'hF000_0000;

    // -------------------------------------------------------------------
    // Private instruction memory (Harvard: fetch never touches the data
    // bus). $readmemh preload from FW_HEX; excore-fw is a Makefile step —
    // the hex is never committed (see excore/tools/asm_rv32.py).
    // -------------------------------------------------------------------
    logic [31:0] imem [0:IMEM_WORDS-1];
    initial begin
        int i;
        for (i = 0; i < IMEM_WORDS; i++) imem[i] = 32'h0000_0013; // NOP (addi x0,x0,0)
        if (FW_HEX != "") $readmemh(FW_HEX, imem);
    end

    // Private scratch RAM (1 KB @ data address 0x0).
    logic [31:0] scratch [0:SCRATCH_WORDS-1];
    initial begin
        int i;
        for (i = 0; i < SCRATCH_WORDS; i++) scratch[i] = 32'h0;
    end

    // -------------------------------------------------------------------
    // Register file. x0 is hardwired zero (never stored, never written).
    // -------------------------------------------------------------------
    logic [31:0] rf [1:31];
    function automatic logic [31:0] rf_read(input logic [4:0] idx);
        rf_read = (idx == 5'd0) ? 32'h0 : rf[idx];
    endfunction

    // -------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------
    localparam logic [1:0] S_FETCH = 2'd0;
    localparam logic [1:0] S_EXEC  = 2'd1;
    localparam logic [1:0] S_MEM   = 2'd2;
    localparam logic [1:0] S_FAULT = 2'd3;

    logic [1:0]  state_r;
    logic [31:0] pc_r;
    logic [31:0] instr_r;
    logic [31:0] mem_pending_pc_r;
    logic [4:0]  mem_rd_r;

    // -------------------------------------------------------------------
    // Decode (combinational, valid while state_r == S_EXEC).
    // -------------------------------------------------------------------
    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;
    assign opcode = instr_r[6:0];
    assign rd     = instr_r[11:7];
    assign funct3 = instr_r[14:12];
    assign rs1    = instr_r[19:15];
    assign rs2    = instr_r[24:20];
    assign funct7 = instr_r[31:25];

    logic signed [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{instr_r[31]}}, instr_r[31:20]};
    assign imm_s = {{20{instr_r[31]}}, instr_r[31:25], instr_r[11:7]};
    assign imm_b = {{19{instr_r[31]}}, instr_r[31], instr_r[7], instr_r[30:25],
                    instr_r[11:8], 1'b0};
    assign imm_u = {instr_r[31:12], 12'b0};
    assign imm_j = {{11{instr_r[31]}}, instr_r[31], instr_r[19:12], instr_r[20],
                    instr_r[30:21], 1'b0};

    logic [31:0] rs1_val, rs2_val;
    assign rs1_val = rf_read(rs1);
    assign rs2_val = rf_read(rs2);

    localparam logic [6:0] OPC_OP_IMM = 7'b0010011;
    localparam logic [6:0] OPC_OP     = 7'b0110011;
    localparam logic [6:0] OPC_LOAD   = 7'b0000011;
    localparam logic [6:0] OPC_STORE  = 7'b0100011;
    localparam logic [6:0] OPC_BRANCH = 7'b1100011;
    localparam logic [6:0] OPC_JALR   = 7'b1100111;
    localparam logic [6:0] OPC_JAL    = 7'b1101111;
    localparam logic [6:0] OPC_LUI    = 7'b0110111;
    localparam logic [6:0] OPC_AUIPC  = 7'b0010111;

    logic is_op_imm, is_op, is_load, is_store, is_branch, is_jalr, is_jal,
          is_lui, is_auipc;
    assign is_op_imm = (opcode == OPC_OP_IMM);
    assign is_op     = (opcode == OPC_OP);
    assign is_load   = (opcode == OPC_LOAD);
    assign is_store  = (opcode == OPC_STORE);
    assign is_branch = (opcode == OPC_BRANCH);
    assign is_jalr   = (opcode == OPC_JALR);
    assign is_jal    = (opcode == OPC_JAL);
    assign is_lui    = (opcode == OPC_LUI);
    assign is_auipc  = (opcode == OPC_AUIPC);

    // Legality of the decoded (opcode, funct3, funct7) combination — the
    // hardware correctness backstop. LOAD/STORE only support funct3=010
    // (word); shifts only support the documented funct7 values.
    logic op_imm_shift_ok, op_legal, decode_legal;
    assign op_imm_shift_ok =
        (funct3 == 3'b001) ? (funct7 == 7'b0000000) :        // SLLI
        (funct3 == 3'b101) ? (funct7 == 7'b0000000 || funct7 == 7'b0100000) : // SRLI/SRAI
        1'b1; // ADDI/SLTI/SLTIU/XORI/ORI/ANDI: funct7 field is imm, not checked
    assign op_legal =
        (funct3 == 3'b000) ? (funct7 == 7'b0000000 || funct7 == 7'b0100000) : // ADD/SUB
        (funct3 == 3'b101) ? (funct7 == 7'b0000000 || funct7 == 7'b0100000) : // SRL/SRA
        (funct7 == 7'b0000000); // SLL/SLT/SLTU/XOR/OR/AND
    assign decode_legal =
        is_lui || is_auipc || is_jal ||
        (is_jalr && funct3 == 3'b000) ||
        (is_branch && (funct3 != 3'b010) && (funct3 != 3'b011)) || // no BLTU/BGEU gap
        (is_load  && funct3 == 3'b010) ||
        (is_store && funct3 == 3'b010) ||
        (is_op_imm && op_imm_shift_ok) ||
        (is_op && op_legal);

    // ALU (shared by OP and OP_IMM).
    logic [31:0] alu_rhs;
    assign alu_rhs = is_op_imm ? imm_i : rs2_val;

    logic [31:0] alu_result;
    logic [4:0]  shamt;
    assign shamt = alu_rhs[4:0];
    always_comb begin
        unique case (funct3)
            3'b000: alu_result = (is_op && funct7[5]) ? (rs1_val - alu_rhs)
                                                        : (rs1_val + alu_rhs);
            3'b001: alu_result = rs1_val << shamt;
            3'b010: alu_result = {31'b0, ($signed(rs1_val) < $signed(alu_rhs))};
            3'b011: alu_result = {31'b0, (rs1_val < alu_rhs)};
            3'b100: alu_result = rs1_val ^ alu_rhs;
            3'b101: alu_result = funct7[5] ? ($signed(rs1_val) >>> shamt)
                                            : (rs1_val >> shamt);
            3'b110: alu_result = rs1_val | alu_rhs;
            3'b111: alu_result = rs1_val & alu_rhs;
            default: alu_result = 32'h0;
        endcase
    end

    // Branch condition.
    logic branch_taken;
    always_comb begin
        unique case (funct3)
            3'b000: branch_taken = (rs1_val == rs2_val);                         // BEQ
            3'b001: branch_taken = (rs1_val != rs2_val);                         // BNE
            3'b100: branch_taken = ($signed(rs1_val) < $signed(rs2_val));        // BLT
            3'b101: branch_taken = ($signed(rs1_val) >= $signed(rs2_val));       // BGE
            3'b110: branch_taken = (rs1_val < rs2_val);                         // BLTU
            3'b111: branch_taken = (rs1_val >= rs2_val);                        // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    logic [31:0] mem_addr;
    assign mem_addr = rs1_val + (is_load ? imm_i : imm_s);

    logic mem_misaligned;
    assign mem_misaligned = (mem_addr[1:0] != 2'b00);

    logic mem_is_scratch, mem_is_mmio, mem_is_oob;
    assign mem_is_scratch = (mem_addr < SCRATCH_LIMIT);
    assign mem_is_mmio    = (mem_addr[31:28] == MMIO_BASE[31:28]);
    assign mem_is_oob     = !mem_is_scratch && !mem_is_mmio;

    logic [31:0] next_pc_seq, next_pc_branch, next_pc_jal, next_pc_jalr;
    assign next_pc_seq    = pc_r + 32'd4;
    assign next_pc_branch = pc_r + imm_b;
    assign next_pc_jal    = pc_r + imm_j;
    assign next_pc_jalr   = (rs1_val + imm_i) & ~32'h1;

    // -------------------------------------------------------------------
    // Sequential
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_r          <= S_FETCH;
            pc_r             <= 32'h0;
            instr_r          <= 32'h0;
            mem_pending_pc_r <= 32'h0;
            mem_rd_r         <= 5'h0;
            fault_o          <= 1'b0;
            fault_pc_o       <= 32'h0;
            mmio_req_o       <= 1'b0;
            mmio_we_o        <= 1'b0;
            mmio_addr_o      <= 32'h0;
            mmio_wdata_o     <= 32'h0;
        end else begin
            unique case (state_r)

                S_FETCH: begin
                    instr_r <= imem[pc_r[IMEM_AW+1:2]];
                    state_r <= S_EXEC;
                end

                S_EXEC: begin
                    if (!decode_legal) begin
                        fault_o    <= 1'b1;
                        fault_pc_o <= pc_r;
                        state_r    <= S_FAULT;
                    end else if (is_load || is_store) begin
                        if (mem_misaligned || mem_is_oob) begin
                            fault_o    <= 1'b1;
                            fault_pc_o <= pc_r;
                            state_r    <= S_FAULT;
                        end else if (mem_is_scratch) begin
                            // Scratch RAM completes in this same cycle: the
                            // array read is combinational (see mem_rdata_comb
                            // below) and the write is issued right here.
                            if (is_store) begin
                                scratch[mem_addr[SCRATCH_AW+1:2]] <= rs2_val;
                            end else if (rd != 5'd0) begin
                                rf[rd] <= scratch[mem_addr[SCRATCH_AW+1:2]];
                            end
                            pc_r    <= next_pc_seq;
                            state_r <= S_FETCH;
                        end else begin
                            // MMIO: issue the bus request, wait for ack.
                            mmio_req_o       <= 1'b1;
                            mmio_we_o        <= is_store;
                            mmio_addr_o      <= mem_addr;
                            mmio_wdata_o     <= rs2_val;
                            mem_rd_r         <= rd;
                            mem_pending_pc_r <= pc_r;
                            state_r          <= S_MEM;
                        end
                    end else begin
                        // ALU / branch / jump / U-type: single-cycle commit.
                        if (is_branch) begin
                            pc_r <= branch_taken ? next_pc_branch : next_pc_seq;
                        end else if (is_jal) begin
                            if (rd != 5'd0) rf[rd] <= next_pc_seq;
                            pc_r <= next_pc_jal;
                        end else if (is_jalr) begin
                            if (rd != 5'd0) rf[rd] <= next_pc_seq;
                            pc_r <= next_pc_jalr;
                        end else begin
                            if (rd != 5'd0) begin
                                if (is_lui)        rf[rd] <= imm_u;
                                else if (is_auipc) rf[rd] <= pc_r + imm_u;
                                else               rf[rd] <= alu_result;
                            end
                            pc_r <= next_pc_seq;
                        end
                        state_r <= S_FETCH;
                    end
                end

                S_MEM: begin
                    mmio_req_o <= 1'b0;
                    if (mmio_ack_i) begin
                        if (!mmio_we_o && (mem_rd_r != 5'd0)) begin
                            rf[mem_rd_r] <= mmio_rdata_i;
                        end
                        pc_r    <= mem_pending_pc_r + 32'd4;
                        state_r <= S_FETCH;
                    end
                end

                S_FAULT: begin
                    // Sticky hardware halt — never observed by correct
                    // firmware, since the firmware never emits an
                    // instruction outside the supported subset.
                    state_r <= S_FAULT;
                end

                default: state_r <= S_FAULT;
            endcase
        end
    end

endmodule
