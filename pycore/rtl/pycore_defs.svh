`ifndef PYCORE_DEFS_SVH
`define PYCORE_DEFS_SVH

localparam int PYCORE_VAL_WIDTH   = 64;
localparam int PYCORE_TAG_WIDTH   = 3;
localparam int PYCORE_ENTRY_WIDTH = PYCORE_TAG_WIDTH + PYCORE_VAL_WIDTH;

localparam logic [2:0] PY_TAG_UNINIT = 3'b000;
localparam logic [2:0] PY_TAG_INT    = 3'b001;
localparam logic [2:0] PY_TAG_FLOAT  = 3'b010;
localparam logic [2:0] PY_TAG_BOOL   = 3'b011;
localparam logic [2:0] PY_TAG_PTR    = 3'b100;
localparam logic [2:0] PY_TAG_OBJECT = 3'b101;

localparam logic [1:0] PY_EXEC_INT   = 2'd0;
localparam logic [1:0] PY_EXEC_FLOAT = 2'd1;
localparam logic [1:0] PY_EXEC_BOOL  = 2'd2;
localparam logic [1:0] PY_EXEC_TRAP  = 2'd3;

localparam logic [1:0] PY_PROMOTE_NONE          = 2'd0;
localparam logic [1:0] PY_PROMOTE_INT_TO_FLOAT  = 2'd1;
localparam logic [1:0] PY_PROMOTE_BOOL_TO_INT   = 2'd2;
localparam logic [1:0] PY_PROMOTE_BOOL_TO_FLOAT = 2'd3;

localparam logic [3:0] PY_TRAP_NONE           = 4'd0;
localparam logic [3:0] PY_TRAP_TYPE           = 4'd1;
localparam logic [3:0] PY_TRAP_STACK          = 4'd2;
localparam logic [3:0] PY_TRAP_DIV_ZERO       = 4'd3;
localparam logic [3:0] PY_TRAP_FPU_EXCEPTION  = 4'd4;
localparam logic [3:0] PY_TRAP_ILLEGAL_OPCODE = 4'd5;
localparam logic [3:0] PY_TRAP_CALL_FILTER    = 4'd6;

localparam logic [4:0] PY_ALU_ADD       = 5'd0;
localparam logic [4:0] PY_ALU_SUB       = 5'd1;
localparam logic [4:0] PY_ALU_MUL       = 5'd2;
localparam logic [4:0] PY_ALU_FLOOR_DIV = 5'd3;
localparam logic [4:0] PY_ALU_TRUE_DIV  = 5'd4;
localparam logic [4:0] PY_ALU_MOD       = 5'd5;
localparam logic [4:0] PY_ALU_POWER     = 5'd6;
localparam logic [4:0] PY_ALU_LSHIFT    = 5'd7;
localparam logic [4:0] PY_ALU_RSHIFT    = 5'd8;
localparam logic [4:0] PY_ALU_AND       = 5'd9;
localparam logic [4:0] PY_ALU_OR        = 5'd10;
localparam logic [4:0] PY_ALU_XOR       = 5'd11;
localparam logic [4:0] PY_ALU_NEG       = 5'd12;
localparam logic [4:0] PY_ALU_POS       = 5'd13;
localparam logic [4:0] PY_ALU_INVERT    = 5'd14;
localparam logic [4:0] PY_ALU_NOT       = 5'd15;
localparam logic [4:0] PY_ALU_EQ        = 5'd16;
localparam logic [4:0] PY_ALU_NE        = 5'd17;
localparam logic [4:0] PY_ALU_LT        = 5'd18;
localparam logic [4:0] PY_ALU_LE        = 5'd19;
localparam logic [4:0] PY_ALU_GT        = 5'd20;
localparam logic [4:0] PY_ALU_GE        = 5'd21;
localparam logic [4:0] PY_ALU_PASS      = 5'd22;
localparam logic [4:0] PY_ALU_ILLEGAL   = 5'd31;

localparam logic [7:0] PY_OP_CACHE            = 8'd0;
localparam logic [7:0] PY_OP_POP_TOP          = 8'd1;
localparam logic [7:0] PY_OP_PUSH_NULL        = 8'd2;
localparam logic [7:0] PY_OP_POP_ITER         = 8'd3;
localparam logic [7:0] PY_OP_RETURN_VALUE     = 8'd35;
localparam logic [7:0] PY_OP_BINARY_OP        = 8'd44;
localparam logic [7:0] PY_OP_COMPARE_OP       = 8'd58;
localparam logic [7:0] PY_OP_LOAD_CONST       = 8'd82;
localparam logic [7:0] PY_OP_LOAD_FAST        = 8'd84;
localparam logic [7:0] PY_OP_LOAD_FAST_BORROW = 8'd86;
localparam logic [7:0] PY_OP_LOAD_SMALL_INT   = 8'd94;
localparam logic [7:0] PY_OP_STORE_FAST       = 8'd112;
localparam logic [7:0] PY_OP_POP_JUMP_IF_FALSE = 8'd114;
localparam logic [7:0] PY_OP_POP_JUMP_IF_TRUE  = 8'd115;
localparam logic [7:0] PY_OP_CALL             = 8'd171;
localparam logic [7:0] PY_OP_RESUME           = 8'd128;
localparam logic [7:0] PY_OP_EXTENDED_ARG     = 8'd144;
localparam logic [7:0] PY_OP_JUMP_FORWARD     = 8'd110;
localparam logic [7:0] PY_OP_JUMP_BACKWARD    = 8'd140;

localparam logic [2:0] PY_MEM_NONE       = 3'd0;
localparam logic [2:0] PY_MEM_LOAD_FAST  = 3'd1;
localparam logic [2:0] PY_MEM_STORE_FAST = 3'd2;
localparam logic [2:0] PY_MEM_LOAD_CONST = 3'd3;

function automatic logic pycore_is_numeric_tag(input logic [2:0] tag);
    begin
        pycore_is_numeric_tag = (tag == PY_TAG_INT) || (tag == PY_TAG_FLOAT) || (tag == PY_TAG_BOOL);
    end
endfunction

function automatic logic pycore_is_trapping_tag(input logic [2:0] tag);
    begin
        pycore_is_trapping_tag = (tag == PY_TAG_UNINIT) || (tag == PY_TAG_PTR) ||
                                 (tag == PY_TAG_OBJECT) || tag[2:1] == 2'b11;
    end
endfunction

`endif
