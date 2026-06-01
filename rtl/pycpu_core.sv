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
    output logic                     illegal_instr_valid,
    output logic                     ret_valid,
    output logic signed [WORD_W-1:0] ret_value
);

    typedef logic [7:0] opcode_t;
    // Opcode numbering tracks CPython 3.14 (strict). Verified against
    // opcode.opmap on Python 3.14.3.
    localparam opcode_t OP_NOP              = 8'd27;
    localparam opcode_t OP_RETURN_VALUE     = 8'd35;
    localparam opcode_t OP_BINARY_OP        = 8'd44;
    localparam opcode_t OP_LOAD_CONST       = 8'd82;
    localparam opcode_t OP_LOAD_FAST        = 8'd84;
    localparam opcode_t OP_LOAD_FAST_BORROW = 8'd86;
    localparam opcode_t OP_LOAD_SMALL_INT   = 8'd94;
    localparam opcode_t OP_STORE_FAST       = 8'd112;
    localparam opcode_t OP_RESUME           = 8'd128;

    localparam logic [7:0] BINARY_ADD             = 8'd0;
    localparam logic [7:0] BINARY_AND             = 8'd1;
    localparam logic [7:0] BINARY_FLOOR_DIV       = 8'd2;
    localparam logic [7:0] BINARY_LSHIFT          = 8'd3;
    localparam logic [7:0] BINARY_MATRIX_MUL      = 8'd4;
    localparam logic [7:0] BINARY_MUL             = 8'd5;
    localparam logic [7:0] BINARY_MOD             = 8'd6;
    localparam logic [7:0] BINARY_OR              = 8'd7;
    localparam logic [7:0] BINARY_POW             = 8'd8;
    localparam logic [7:0] BINARY_RSHIFT          = 8'd9;
    localparam logic [7:0] BINARY_SUB             = 8'd10;
    localparam logic [7:0] BINARY_TRUE_DIV        = 8'd11;
    localparam logic [7:0] BINARY_XOR             = 8'd12;
    localparam logic [7:0] BINARY_INPLACE_ADD     = 8'd13;
    localparam logic [7:0] BINARY_INPLACE_AND     = 8'd14;
    localparam logic [7:0] BINARY_INPLACE_FLOOR_DIV = 8'd15;
    localparam logic [7:0] BINARY_INPLACE_LSHIFT  = 8'd16;
    localparam logic [7:0] BINARY_INPLACE_MATRIX_MUL = 8'd17;
    localparam logic [7:0] BINARY_INPLACE_MUL     = 8'd18;
    localparam logic [7:0] BINARY_INPLACE_MOD     = 8'd19;
    localparam logic [7:0] BINARY_INPLACE_OR      = 8'd20;
    localparam logic [7:0] BINARY_INPLACE_POW     = 8'd21;
    localparam logic [7:0] BINARY_INPLACE_RSHIFT  = 8'd22;
    localparam logic [7:0] BINARY_INPLACE_SUB     = 8'd23;
    localparam logic [7:0] BINARY_INPLACE_TRUE_DIV = 8'd24;
    localparam logic [7:0] BINARY_INPLACE_XOR     = 8'd25;

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

    function automatic logic signed [WORD_W-1:0] py_floor_div(
        input logic signed [WORD_W-1:0] lhs,
        input logic signed [WORD_W-1:0] rhs
    );
        logic signed [WORD_W-1:0] q;
        logic signed [WORD_W-1:0] r;
        begin
            q = lhs / rhs;
            r = lhs % rhs;
            if ((r != 0) && ((r > 0 && rhs < 0) || (r < 0 && rhs > 0))) begin
                q = q - 1;
            end
            py_floor_div = q;
        end
    endfunction

    function automatic logic signed [WORD_W-1:0] py_floor_mod(
        input logic signed [WORD_W-1:0] lhs,
        input logic signed [WORD_W-1:0] rhs
    );
        logic signed [WORD_W-1:0] q;
        begin
            q = py_floor_div(lhs, rhs);
            py_floor_mod = lhs - (q * rhs);
        end
    endfunction

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
            illegal_instr_valid <= 1'b0;
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
            illegal_instr_valid <= 1'b0;

            if (wb_valid && !halted) begin
                unique case (wb_opcode)
                    OP_LOAD_CONST, OP_LOAD_FAST, OP_LOAD_FAST_BORROW, OP_LOAD_SMALL_INT: begin
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
                        illegal_instr_valid <= 1'b1;
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

                    OP_LOAD_FAST, OP_LOAD_FAST_BORROW: begin
                        if (ex_oparg < LOCAL_COUNT) begin
                            mem_result <= local_mem[ex_oparg];
                        end else begin
                            execute_fault = 1'b1;
                        end
                    end

                    OP_LOAD_SMALL_INT: begin
                        mem_result <= {{(WORD_W-8){1'b0}}, ex_oparg};
                    end

                    OP_STORE_FAST: begin
                        mem_result <= ex_a;
                    end

                    OP_BINARY_OP: begin
                        unique case (ex_oparg)
                            BINARY_ADD, BINARY_INPLACE_ADD: begin
                                mem_result <= ex_a + ex_b;
                            end
                            BINARY_SUB, BINARY_INPLACE_SUB: begin
                                mem_result <= ex_a - ex_b;
                            end
                            BINARY_MUL, BINARY_INPLACE_MUL: begin
                                mem_result <= ex_a * ex_b;
                            end
                            BINARY_AND, BINARY_INPLACE_AND: begin
                                mem_result <= ex_a & ex_b;
                            end
                            BINARY_OR, BINARY_INPLACE_OR: begin
                                mem_result <= ex_a | ex_b;
                            end
                            BINARY_XOR, BINARY_INPLACE_XOR: begin
                                mem_result <= ex_a ^ ex_b;
                            end
                            BINARY_FLOOR_DIV, BINARY_INPLACE_FLOOR_DIV: begin
                                if (ex_b != 0) begin
                                    mem_result <= py_floor_div(ex_a, ex_b);
                                end else begin
                                    execute_fault = 1'b1;
                                end
                            end
                            BINARY_MOD, BINARY_INPLACE_MOD: begin
                                if (ex_b != 0) begin
                                    mem_result <= py_floor_mod(ex_a, ex_b);
                                end else begin
                                    execute_fault = 1'b1;
                                end
                            end
                            BINARY_POW, BINARY_INPLACE_POW: begin
                                if (ex_b >= 0) begin
                                    mem_result <= ex_a ** ex_b;
                                end else begin
                                    execute_fault = 1'b1;
                                end
                            end
                            BINARY_LSHIFT, BINARY_INPLACE_LSHIFT: begin
                                if (ex_b >= 0) begin
                                    if (ex_b >= WORD_W) begin
                                        mem_result <= '0;
                                    end else begin
                                        mem_result <= ex_a <<< ex_b;
                                    end
                                end else begin
                                    execute_fault = 1'b1;
                                end
                            end
                            BINARY_RSHIFT, BINARY_INPLACE_RSHIFT: begin
                                if (ex_b >= 0) begin
                                    if (ex_b >= WORD_W) begin
                                        mem_result <= ex_a[WORD_W-1] ? '1 : '0;
                                    end else begin
                                        mem_result <= ex_a >>> ex_b;
                                    end
                                end else begin
                                    execute_fault = 1'b1;
                                end
                            end
                            BINARY_MATRIX_MUL, BINARY_INPLACE_MATRIX_MUL,
                            BINARY_TRUE_DIV, BINARY_INPLACE_TRUE_DIV: begin
                                execute_fault = 1'b1;
                                illegal_instr_valid <= 1'b1;
                            end
                            default: begin
                                execute_fault = 1'b1;
                                illegal_instr_valid <= 1'b1;
                            end
                        endcase
                    end

                    OP_RETURN_VALUE: begin
                        mem_result <= ex_a;
                    end

                    OP_NOP, OP_RESUME: begin
                    end

                    default: begin
                        execute_fault = 1'b1;
                        illegal_instr_valid <= 1'b1;
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
