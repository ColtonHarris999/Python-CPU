module pycpu_core #(
    parameter int WORD_W = 32,
    parameter int PROG_DEPTH = 256,
    parameter int CONST_DEPTH = 256,
    parameter int LOCAL_COUNT = 32,
    parameter int STACK_DEPTH = 64,
    parameter string PROG_HEX = "programs/demo_prog.hex",
    parameter string CONST_HEX = "programs/demo_consts.hex"
) (
    input  logic                     clk,
    input  logic                     rst_n,
    output logic                     halted,
    output logic                     trap_valid,
    output logic                     ret_valid,
    output logic signed [WORD_W-1:0] ret_value
);

    typedef logic [7:0] opcode_t;
    localparam opcode_t OP_NOP          = 8'd9;
    localparam opcode_t OP_RETURN_VALUE = 8'd83;
    localparam opcode_t OP_LOAD_CONST   = 8'd100;
    localparam opcode_t OP_BINARY_OP    = 8'd122;
    localparam opcode_t OP_LOAD_FAST    = 8'd124;
    localparam opcode_t OP_STORE_FAST   = 8'd125;
    localparam opcode_t OP_RESUME       = 8'd151;

    localparam logic [7:0] BINARY_ADD = 8'd0;
    localparam logic [7:0] BINARY_MUL = 8'd5;
    localparam logic [7:0] BINARY_SUB = 8'd10;

    localparam int PC_W = $clog2(PROG_DEPTH);
    localparam int SP_W = $clog2(STACK_DEPTH + 1);

    logic [15:0]                     instr_mem [0:PROG_DEPTH-1];
    logic signed [WORD_W-1:0]        const_mem [0:CONST_DEPTH-1];
    logic signed [WORD_W-1:0]        local_mem [0:LOCAL_COUNT-1];
    logic signed [WORD_W-1:0]        stack_mem [0:STACK_DEPTH-1];

    logic [PC_W-1:0]                 pc;
    logic [SP_W-1:0]                 sp;

    logic                            if_valid;
    logic [PC_W-1:0]                 if_pc;
    logic [15:0]                     if_instr;

    logic                            id_valid;
    logic [PC_W-1:0]                 id_pc;
    opcode_t                         id_opcode;
    logic [7:0]                      id_oparg;

    logic                            ex_valid;
    logic [PC_W-1:0]                 ex_pc;
    opcode_t                         ex_opcode;
    logic [7:0]                      ex_oparg;
    logic signed [WORD_W-1:0]        ex_a;
    logic signed [WORD_W-1:0]        ex_b;

    logic                            mem_valid;
    logic [PC_W-1:0]                 mem_pc;
    opcode_t                         mem_opcode;
    logic [7:0]                      mem_oparg;
    logic signed [WORD_W-1:0]        mem_result;

    logic                            wb_valid;
    logic [PC_W-1:0]                 wb_pc;
    opcode_t                         wb_opcode;
    logic [7:0]                      wb_oparg;
    logic signed [WORD_W-1:0]        wb_result;

    initial begin
        $readmemh(PROG_HEX, instr_mem);
        $readmemh(CONST_HEX, const_mem);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        bit decode_fault;
        bit execute_fault;
        bit squash_pipe;

        if (!rst_n) begin
            int i;
            pc        <= '0;
            sp        <= '0;
            halted    <= 1'b0;
            trap_valid <= 1'b0;
            ret_valid <= 1'b0;
            ret_value <= '0;

            if_valid  <= 1'b0;
            if_pc     <= '0;
            if_instr  <= '0;

            id_valid  <= 1'b0;
            id_pc     <= '0;
            id_opcode <= '0;
            id_oparg  <= '0;

            ex_valid  <= 1'b0;
            ex_pc     <= '0;
            ex_opcode <= '0;
            ex_oparg  <= '0;
            ex_a      <= '0;
            ex_b      <= '0;

            mem_valid  <= 1'b0;
            mem_pc     <= '0;
            mem_opcode <= '0;
            mem_oparg  <= '0;
            mem_result <= '0;

            wb_valid  <= 1'b0;
            wb_pc     <= '0;
            wb_opcode <= '0;
            wb_oparg  <= '0;
            wb_result <= '0;

            for (i = 0; i < LOCAL_COUNT; i++) begin
                local_mem[i] <= '0;
            end
            for (i = 0; i < STACK_DEPTH; i++) begin
                stack_mem[i] <= '0;
            end
        end else begin
            decode_fault = 1'b0;
            execute_fault = 1'b0;
            squash_pipe = 1'b0;

            ret_valid  <= 1'b0;
            trap_valid <= 1'b0;

            if (wb_valid && !halted) begin
                unique case (wb_opcode)
                    OP_LOAD_CONST, OP_LOAD_FAST: begin
                        if (sp < STACK_DEPTH) begin
                            stack_mem[sp] <= wb_result;
                            sp <= sp + 1'b1;
                        end else begin
                            halted <= 1'b1;
                            trap_valid <= 1'b1;
                            squash_pipe = 1'b1;
                        end
                    end

                    OP_STORE_FAST: begin
                        if (sp > 0 && wb_oparg < LOCAL_COUNT) begin
                            local_mem[wb_oparg] <= wb_result;
                            sp <= sp - 1'b1;
                        end else begin
                            halted <= 1'b1;
                            trap_valid <= 1'b1;
                            squash_pipe = 1'b1;
                        end
                    end

                    OP_BINARY_OP: begin
                        if (sp > 1) begin
                            stack_mem[sp-2] <= wb_result;
                            sp <= sp - 1'b1;
                        end else begin
                            halted <= 1'b1;
                            trap_valid <= 1'b1;
                            squash_pipe = 1'b1;
                        end
                    end

                    OP_RETURN_VALUE: begin
                        if (sp > 0) begin
                            ret_value <= wb_result;
                            ret_valid <= 1'b1;
                            sp <= sp - 1'b1;
                            halted <= 1'b1;
                            squash_pipe = 1'b1;
                        end else begin
                            halted <= 1'b1;
                            trap_valid <= 1'b1;
                            squash_pipe = 1'b1;
                        end
                    end

                    OP_NOP, OP_RESUME: begin
                    end

                    default: begin
                        halted <= 1'b1;
                        trap_valid <= 1'b1;
                        squash_pipe = 1'b1;
                    end
                endcase
            end

            wb_valid  <= mem_valid;
            wb_pc     <= mem_pc;
            wb_opcode <= mem_opcode;
            wb_oparg  <= mem_oparg;
            wb_result <= mem_result;

            mem_valid  <= ex_valid;
            mem_pc     <= ex_pc;
            mem_opcode <= ex_opcode;
            mem_oparg  <= ex_oparg;
            mem_result <= '0;

            if (ex_valid && !halted) begin
                unique case (ex_opcode)
                    OP_LOAD_CONST: begin
                        if (ex_oparg < CONST_DEPTH) begin
                            mem_result <= const_mem[ex_oparg];
                        end else begin
                            execute_fault = 1'b1;
                        end
                    end

                    OP_LOAD_FAST: begin
                        if (ex_oparg < LOCAL_COUNT) begin
                            mem_result <= local_mem[ex_oparg];
                        end else begin
                            execute_fault = 1'b1;
                        end
                    end

                    OP_STORE_FAST: begin
                        mem_result <= ex_a;
                    end

                    OP_BINARY_OP: begin
                        unique case (ex_oparg)
                            BINARY_ADD: mem_result <= ex_a + ex_b;
                            BINARY_SUB: mem_result <= ex_a - ex_b;
                            BINARY_MUL: mem_result <= ex_a * ex_b;
                            default: execute_fault = 1'b1;
                        endcase
                    end

                    OP_RETURN_VALUE: begin
                        mem_result <= ex_a;
                    end

                    OP_NOP, OP_RESUME: begin
                    end

                    default: begin
                        execute_fault = 1'b1;
                    end
                endcase
            end

            if (execute_fault) begin
                mem_valid <= 1'b0;
                halted <= 1'b1;
                trap_valid <= 1'b1;
                squash_pipe = 1'b1;
            end

            ex_valid  <= id_valid;
            ex_pc     <= id_pc;
            ex_opcode <= id_opcode;
            ex_oparg  <= id_oparg;
            ex_a      <= '0;
            ex_b      <= '0;

            if (id_valid && !halted) begin
                unique case (id_opcode)
                    OP_STORE_FAST, OP_RETURN_VALUE: begin
                        if (sp > 0) begin
                            ex_a <= stack_mem[sp-1];
                        end else begin
                            decode_fault = 1'b1;
                        end
                    end

                    OP_BINARY_OP: begin
                        if (sp > 1) begin
                            ex_a <= stack_mem[sp-2];
                            ex_b <= stack_mem[sp-1];
                        end else begin
                            decode_fault = 1'b1;
                        end
                    end

                    default: begin
                    end
                endcase
            end

            if (decode_fault) begin
                ex_valid <= 1'b0;
                halted <= 1'b1;
                trap_valid <= 1'b1;
                squash_pipe = 1'b1;
            end

            id_valid  <= if_valid;
            id_pc     <= if_pc;
            id_opcode <= if_instr[7:0];
            id_oparg  <= if_instr[15:8];

            if_valid <= 1'b0;
            if_pc    <= '0;
            if_instr <= '0;

            if (!halted && !(if_valid || id_valid || ex_valid || mem_valid || wb_valid)) begin
                if_valid <= 1'b1;
                if_pc <= pc;
                if_instr <= instr_mem[pc];
                if (pc < PROG_DEPTH - 1) begin
                    pc <= pc + 1'b1;
                end
            end

            if (squash_pipe) begin
                if_valid <= 1'b0;
                id_valid <= 1'b0;
                ex_valid <= 1'b0;
                mem_valid <= 1'b0;
                wb_valid <= 1'b0;
            end
        end
    end

endmodule
