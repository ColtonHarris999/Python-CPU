`include "pycore_defs.svh"

// Decode for RF_DEPTH up to 256: stack/local indices and RF selects are 8-bit.
module pycore_decode (
    input  logic        instr_valid_i,
    input  logic [7:0]  opcode_i,
    input  logic [31:0] arg_i,
    input  logic [31:0] pc_i,
    input  logic [7:0]  tos_index_i,
    input  logic [7:0]  locals_base_i,
    output logic        decoded_valid_o,
    output logic [4:0]  alu_op_o,
    output logic [7:0]  rs1_sel_o,
    output logic [7:0]  rs2_sel_o,
    output logic [7:0]  rd_sel_o,
    output logic        is_branch_o,
    output logic        is_call_o,
    output logic        is_return_o,
    // Asserted for multi-cycle container / name / const-table operations
    // handled by S_CONTAINER (bypass S_MEM and S_WB).
    output logic        is_container_o,
    output logic        push_stack_o,
    output logic        pop_stack_o,
    output logic [2:0]  mem_op_o,
    output logic        illegal_opcode_o,
    output logic [31:0] decoded_pc_o
);

    function automatic logic [4:0] decode_binary_op(input logic [7:0] subop);
        begin
            unique case (subop)
                8'd0, 8'd13:  decode_binary_op = PY_ALU_ADD;
                8'd1, 8'd14:  decode_binary_op = PY_ALU_AND;
                8'd2, 8'd15:  decode_binary_op = PY_ALU_FLOOR_DIV;
                8'd3, 8'd16:  decode_binary_op = PY_ALU_LSHIFT;
                8'd5, 8'd18:  decode_binary_op = PY_ALU_MUL;
                8'd6, 8'd19:  decode_binary_op = PY_ALU_MOD;
                8'd7, 8'd20:  decode_binary_op = PY_ALU_OR;
                8'd8, 8'd21:  decode_binary_op = PY_ALU_POWER;
                8'd9, 8'd22:  decode_binary_op = PY_ALU_RSHIFT;
                8'd10, 8'd23: decode_binary_op = PY_ALU_SUB;
                8'd11, 8'd24: decode_binary_op = PY_ALU_TRUE_DIV;
                8'd12, 8'd25: decode_binary_op = PY_ALU_XOR;
                // NB_SUBSCR (oparg=26): subscript read x[k].  Routes to the
                // S_CONTAINER multi-cycle path rather than the execute fabric.
                PY_NBARG_SUBSCR: decode_binary_op = PY_ALU_SUBSCR;
                default:      decode_binary_op = PY_ALU_ILLEGAL;
            endcase
        end
    endfunction

    // CPython 3.14 COMPARE_OP: comparison selector is oparg >> 5.  Bits
    // 4:0 carry the force-bool flag and quickening mask; the image builder
    // validates those packed forms, and native compares already return BOOL.
    function automatic logic [4:0] decode_compare_op(input logic [7:0] cmp);
        begin
            unique case (cmp[7:5])
                3'd0: decode_compare_op = PY_ALU_LT;
                3'd1: decode_compare_op = PY_ALU_LE;
                3'd2: decode_compare_op = PY_ALU_EQ;
                3'd3: decode_compare_op = PY_ALU_NE;
                3'd4: decode_compare_op = PY_ALU_GT;
                3'd5: decode_compare_op = PY_ALU_GE;
                default: decode_compare_op = PY_ALU_ILLEGAL;
            endcase
        end
    endfunction

    always_comb begin
        decoded_valid_o = instr_valid_i;
        alu_op_o = PY_ALU_PASS;
        rs1_sel_o = 8'b0;
        rs2_sel_o = 8'b0;
        rd_sel_o = 8'b0;
        is_branch_o = 1'b0;
        is_call_o = 1'b0;
        is_return_o = 1'b0;
        is_container_o = 1'b0;
        push_stack_o = 1'b0;
        pop_stack_o = 1'b0;
        mem_op_o = PY_MEM_NONE;
        illegal_opcode_o = 1'b0;
        decoded_pc_o = pc_i;

        unique case (opcode_i)
            PY_OP_RESUME, PY_OP_NOT_TAKEN, PY_OP_NOP: begin
                // NOT_TAKEN / NOP are monitoring / peephole no-ops in 3.14.
            end

            // LOAD_FAST_CHECK: same datapath as LOAD_FAST; EX traps on UNINIT.
            PY_OP_LOAD_FAST, PY_OP_LOAD_FAST_BORROW, PY_OP_LOAD_FAST_CHECK: begin
                rs1_sel_o = locals_base_i + arg_i[7:0];
                rd_sel_o = tos_index_i;
                push_stack_o = 1'b1;
                mem_op_o = PY_MEM_LOAD_FAST;
            end

            // Combined load: arg[7:4]=first, arg[3:0]=second. Handled as a
            // two-beat container op so the image path can keep 1:1 encoding.
            // LOAD_FAST_LOAD_FAST shares CONT_LFB_PAIR (borrow≡owned in HW).
            PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW,
            PY_OP_LOAD_FAST_LOAD_FAST: begin
                is_container_o = 1'b1;
            end

            // LOAD_FAST_AND_CLEAR: latch local in rs1; CONT_LFAC pushes then
            // clears the slot to UNINIT (two-beat; unbound does not trap).
            PY_OP_LOAD_FAST_AND_CLEAR: begin
                rs1_sel_o = locals_base_i + arg_i[7:0];
                is_container_o = 1'b1;
            end

            PY_OP_STORE_FAST: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o = locals_base_i + arg_i[7:0];
                pop_stack_o = 1'b1;
                mem_op_o = PY_MEM_STORE_FAST;
            end

            // STORE_FAST_LOAD_FAST / STORE_FAST_STORE_FAST: nibble oparg
            // (hi<<4)|lo.  Latch TOS in rs1 for the first store beat.
            PY_OP_STORE_FAST_LOAD_FAST,
            PY_OP_STORE_FAST_STORE_FAST: begin
                rs1_sel_o = tos_index_i - 8'd1;
                is_container_o = 1'b1;
            end

            // DELETE_FAST: clear local oparg to UNINIT (net stack 0).
            // Reads the slot for the unbound check; writes the same address.
            PY_OP_DELETE_FAST: begin
                rs1_sel_o = locals_base_i + arg_i[7:0];
                rd_sel_o  = locals_base_i + arg_i[7:0];
            end

            PY_OP_LOAD_SMALL_INT: begin
                rd_sel_o = tos_index_i;
                push_stack_o = 1'b1;
            end

            // COPY oparg: push a duplicate of the stack entry at depth oparg
            // (stack[-oparg]).  Clone of the LOAD_FAST datapath: read one RF
            // slot and push it verbatim through EX/MEM.  oparg is 1-based and
            // never 0 in valid CPython bytecode (COPY 1 duplicates TOS).
            PY_OP_COPY: begin
                rs1_sel_o = tos_index_i - arg_i[7:0];
                rd_sel_o = tos_index_i;
                push_stack_o = 1'b1;
                mem_op_o = PY_MEM_LOAD_FAST;
            end

            // SWAP oparg: exchange TOS with stack[-oparg].  Dual RF read in
            // decode; two-beat CONT_SWAP writeback (single RF write port).
            // oparg is 1-based; valid CPython bytecode uses oparg >= 2.
            PY_OP_SWAP: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rs2_sel_o = tos_index_i - arg_i[7:0];
                is_container_o = 1'b1;
            end

            // LOAD_CONST: read co_consts[arg] via CONT_LOAD_CONST.
            PY_OP_LOAD_CONST: begin
                is_container_o = 1'b1;
            end

            // PUSH_NULL: push CONTROL/PY_CTL_NULL (self_or_null sentinel).
            PY_OP_PUSH_NULL: begin
                rd_sel_o = tos_index_i;
                push_stack_o = 1'b1;
            end

            // TO_BOOL: convert TOS numeric to BOOL in place (net stack 0).
            PY_OP_TO_BOOL: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o  = tos_index_i - 8'd1;
                alu_op_o  = PY_ALU_PASS;  // conversion done in core EX
            end

            // UNARY_NOT: invert TOS BOOL in place (net stack 0). CPython 3.14
            // always emits TO_BOOL immediately before; non-BOOL traps in EX.
            PY_OP_UNARY_NOT: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o  = tos_index_i - 8'd1;
                alu_op_o  = PY_ALU_PASS;  // invert done in core EX
            end

            // UNARY_INVERT / UNARY_NEGATIVE: rewrite TOS via ALU fabric
            // (PY_ALU_INVERT / PY_ALU_NEG). Net stack 0.
            PY_OP_UNARY_INVERT: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o  = tos_index_i - 8'd1;
                alu_op_o  = PY_ALU_INVERT;
            end

            PY_OP_UNARY_NEGATIVE: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o  = tos_index_i - 8'd1;
                alu_op_o  = PY_ALU_NEG;
            end

            // UNPACK_SEQUENCE: pop LIST/TUPLE, push count items right-to-left.
            PY_OP_UNPACK_SEQUENCE: begin
                rs1_sel_o      = tos_index_i - 8'd1;
                is_container_o = 1'b1;
            end

            // MAKE_FUNCTION: pop code / push function (≡ code). Net effect 0.
            // Verified in EXEC: trap TYPE if TOS is not CODE_OBJECT.
            PY_OP_MAKE_FUNCTION: begin
                rs1_sel_o = tos_index_i - 8'd1;
            end

            PY_OP_END_FOR, PY_OP_POP_TOP, PY_OP_POP_ITER: begin
                pop_stack_o = 1'b1;
            end

            // GET_ITER rewrites the iterable at TOS with internal iterator
            // state. FOR_ITER reads that state and either pushes the next
            // element or redirects over END_FOR to POP_ITER on exhaustion.
            PY_OP_GET_ITER, PY_OP_FOR_ITER: begin
                rs1_sel_o      = tos_index_i - 8'd1;
                is_container_o = 1'b1;
            end

            PY_OP_BINARY_OP: begin
                rs1_sel_o = tos_index_i - 8'd2;
                rs2_sel_o = tos_index_i - 8'd1;
                rd_sel_o = tos_index_i - 8'd2;
                alu_op_o = decode_binary_op(arg_i[7:0]);
                if (alu_op_o == PY_ALU_SUBSCR) begin
                    is_container_o = 1'b1;
                end else begin
                    pop_stack_o = 1'b1;
                    illegal_opcode_o = alu_op_o == PY_ALU_ILLEGAL;
                end
            end

            PY_OP_COMPARE_OP: begin
                rs1_sel_o = tos_index_i - 8'd2;
                rs2_sel_o = tos_index_i - 8'd1;
                rd_sel_o = tos_index_i - 8'd2;
                pop_stack_o = 1'b1;
                alu_op_o = decode_compare_op(arg_i[7:0]);
                illegal_opcode_o = alu_op_o == PY_ALU_ILLEGAL;
            end

            // IS_OP: identity compare (is / is not). Same stack shape as
            // COMPARE_OP; result built in core EX from full RF-entry equality.
            PY_OP_IS_OP: begin
                rs1_sel_o = tos_index_i - 8'd2;
                rs2_sel_o = tos_index_i - 8'd1;
                rd_sel_o = tos_index_i - 8'd2;
                pop_stack_o = 1'b1;
                alu_op_o = PY_ALU_PASS;
            end

            PY_OP_RETURN_VALUE: begin
                rs1_sel_o = tos_index_i - 8'd1;
                pop_stack_o = 1'b1;
                is_return_o = 1'b1;
                alu_op_o = PY_ALU_PASS;
            end

            PY_OP_JUMP_FORWARD, PY_OP_JUMP_BACKWARD,
            PY_OP_POP_JUMP_IF_TRUE, PY_OP_POP_JUMP_IF_FALSE,
            PY_OP_POP_JUMP_IF_NONE, PY_OP_POP_JUMP_IF_NOT_NONE: begin
                is_branch_o = 1'b1;
                if (opcode_i == PY_OP_POP_JUMP_IF_TRUE ||
                    opcode_i == PY_OP_POP_JUMP_IF_FALSE ||
                    opcode_i == PY_OP_POP_JUMP_IF_NONE ||
                    opcode_i == PY_OP_POP_JUMP_IF_NOT_NONE) begin
                    rs1_sel_o = tos_index_i - 8'd1;
                    pop_stack_o = 1'b1;
                end
            end

            PY_OP_CALL: begin
                is_call_o = 1'b1;
            end

            // LOAD_GLOBAL / LOAD_NAME / STORE_*: multi-cycle name dict ops.
            PY_OP_LOAD_GLOBAL, PY_OP_LOAD_NAME: begin
                is_container_o = 1'b1;
            end

            PY_OP_STORE_NAME, PY_OP_STORE_GLOBAL: begin
                is_container_o = 1'b1;
            end

            // LOAD_ATTR: receiver at tos-1; name from co_names[oparg>>1].
            // STORE_ATTR: obj at tos-1, value at tos-2; namei = oparg.
            // DELETE_ATTR: obj at tos-1; namei = oparg.
            PY_OP_LOAD_ATTR: begin
                rs1_sel_o      = tos_index_i - 8'd1;
                is_container_o = 1'b1;
            end

            PY_OP_STORE_ATTR: begin
                rs1_sel_o      = tos_index_i - 8'd1;  // object
                is_container_o = 1'b1;
            end

            PY_OP_DELETE_ATTR: begin
                rs1_sel_o      = tos_index_i - 8'd1;  // object
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_LIST: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_MAP: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_SET: begin
                is_container_o = 1'b1;
            end

            PY_OP_BUILD_TUPLE: begin
                is_container_o = 1'b1;
            end

            PY_OP_STORE_SUBSCR: begin
                rs1_sel_o = tos_index_i - 8'd1;  // key
                rs2_sel_o = tos_index_i - 8'd2;  // container
                is_container_o = 1'b1;
            end

            // DELETE_SUBSCR: same key/container wiring as STORE_SUBSCR; both
            // popped by the container FSM (no value operand).
            PY_OP_DELETE_SUBSCR: begin
                rs1_sel_o = tos_index_i - 8'd1;  // key
                rs2_sel_o = tos_index_i - 8'd2;  // container
                is_container_o = 1'b1;
            end

            // CONTAINS_OP: needle at tos-2, container at tos-1; BOOL result
            // replaces both (pop 1). oparg[0]=1 inverts (not in).
            PY_OP_CONTAINS_OP: begin
                rs1_sel_o = tos_index_i - 8'd2;  // needle
                rs2_sel_o = tos_index_i - 8'd1;  // container
                is_container_o = 1'b1;
            end

            // LIST_APPEND: list handle at RF[tos-1-arg], element at RF[tos-1]
            // (popped).  See pycore_defs.svh for the verified stack layout.
            PY_OP_LIST_APPEND: begin
                rs1_sel_o = tos_index_i - 8'd1 - arg_i[7:0];  // list handle
                rs2_sel_o = tos_index_i - 8'd1;               // element
                is_container_o = 1'b1;
            end

            // LIST_EXTEND: list handle at RF[tos-1-arg], iterable at RF[tos-1]
            // (popped).  Same stack shape as LIST_APPEND.
            PY_OP_LIST_EXTEND: begin
                rs1_sel_o = tos_index_i - 8'd1 - arg_i[7:0];  // list handle
                rs2_sel_o = tos_index_i - 8'd1;               // iterable
                is_container_o = 1'b1;
            end

            // SET_ADD: set handle at RF[tos-1-arg], element at RF[tos-1].
            PY_OP_SET_ADD: begin
                rs1_sel_o = tos_index_i - 8'd1 - arg_i[7:0];  // set handle
                rs2_sel_o = tos_index_i - 8'd1;               // element
                is_container_o = 1'b1;
            end

            // SET_UPDATE: set at RF[tos-1-arg], iterable at TOS; always traps.
            PY_OP_SET_UPDATE: begin
                rs1_sel_o = tos_index_i - 8'd1 - arg_i[7:0];  // set handle
                rs2_sel_o = tos_index_i - 8'd1;               // iterable
                is_container_o = 1'b1;
            end

            PY_OP_MEM_LOAD_PTR: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rd_sel_o  = tos_index_i - 8'd1;
                mem_op_o  = PY_MEM_LOAD_PTR;
            end

            PY_OP_MEM_STORE_PTR: begin
                rs1_sel_o = tos_index_i - 8'd1;
                rs2_sel_o = tos_index_i - 8'd2;
                pop_stack_o = 1'b1;
                mem_op_o  = PY_MEM_STORE_PTR;
            end

            default: begin
                illegal_opcode_o = 1'b1;
                alu_op_o = PY_ALU_ILLEGAL;
            end
        endcase
    end

endmodule
