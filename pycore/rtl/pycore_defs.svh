`ifndef PYCORE_DEFS_SVH
`define PYCORE_DEFS_SVH

localparam int PYCORE_VAL_WIDTH   = 128;
localparam int PYCORE_TAG_WIDTH   = 4;
localparam int PYCORE_ENTRY_WIDTH = PYCORE_TAG_WIDTH + PYCORE_VAL_WIDTH;

// Tagged-entry slice indices. Centralized here so RTL never hardcodes [131:128]
// or [127:0] when carving a {tag, value} entry apart.
localparam int PYCORE_TAG_MSB = PYCORE_ENTRY_WIDTH - 1;          // 131
localparam int PYCORE_TAG_LSB = PYCORE_VAL_WIDTH;               // 128
localparam int PYCORE_VAL_MSB = PYCORE_VAL_WIDTH - 1;          // 127
localparam int PYCORE_VAL_LSB = 0;                            // 0

// Memory subsystem reference parameters. Memory modules expose these as their
// own parameters; the localparams here document the defaults and let the core
// derive port widths without magic numbers.
localparam int PYCORE_ADDR_WIDTH       = 32;
localparam int PYCORE_BLOCK_SHIFT      = 12;   // 4096 bytes / block
localparam int PYCORE_IMEM_BLOCK_COUNT = 4;    // 16 KB instruction memory
localparam int PYCORE_DMEM_BLOCK_COUNT = 4;    // 16 KB data memory
localparam int PYCORE_IMEM_DATA_WIDTH  = 64;   // one 8-byte instruction slot
localparam int PYCORE_DMEM_DATA_WIDTH  = 128;  // one 128-bit value slot

localparam logic [3:0] PY_TAG_UNINIT       = 4'b0000;
localparam logic [3:0] PY_TAG_INT          = 4'b0001;
localparam logic [3:0] PY_TAG_FLOAT        = 4'b0010;
localparam logic [3:0] PY_TAG_BOOL         = 4'b0011;
localparam logic [3:0] PY_TAG_PTR          = 4'b0100;
localparam logic [3:0] PY_TAG_TUPLE        = 4'b0101;
localparam logic [3:0] PY_TAG_SHORT_STR    = 4'b0110;
localparam logic [3:0] PY_TAG_LONG_STR     = 4'b0111;
localparam logic [3:0] PY_TAG_OBJECT       = 4'b1000;
localparam logic [3:0] PY_TAG_DICT         = 4'b1001;
localparam logic [3:0] PY_TAG_LIST         = 4'b1010;
localparam logic [3:0] PY_TAG_SET          = 4'b1011;
localparam logic [3:0] PY_TAG_CODE_OBJECT  = 4'b1100;
localparam logic [3:0] PY_TAG_FRAME_OBJECT = 4'b1101;
localparam logic [3:0] PY_TAG_UNUSED       = 4'b1110;
localparam logic [3:0] PY_TAG_NONE         = 4'b1111;

localparam int PYCORE_SHORT_STR_MAX_BYTES = 15;
localparam int PYCORE_SHORT_STR_SIZE_MSB  = 127;
localparam int PYCORE_SHORT_STR_SIZE_LSB  = 124;
localparam int PYCORE_SHORT_STR_DATA_MSB  = 123;
localparam int PYCORE_SHORT_STR_DATA_LSB  = 4;
localparam int PYCORE_SHORT_STR_FLAG_MSB  = 3;
localparam int PYCORE_SHORT_STR_FLAG_LSB  = 0;

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
localparam logic [3:0] PY_TRAP_MEM_FAULT      = 4'd7;
localparam logic [3:0] PY_TRAP_ADDR_ALIGN     = 4'd8;

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
// PY_ALU_SUBSCR routes BINARY_OP NB_SUBSCR to the S_CONTAINER FSM path rather
// than to the arithmetic execute fabric.  Values 24-30 are reserved for future
// ALU operations; ILLEGAL remains 31 to catch undecodable opargs.
localparam logic [4:0] PY_ALU_SUBSCR   = 5'd23;
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

// Container / subscript opcodes added in PyCore dict-list support.
// Opcode integers resolved from the CPython 3.14 interpreter:
//   python3.14 -c "import opcode; [print(n,opcode.opmap[n]) for n in \
//       ['BUILD_LIST','BUILD_MAP','STORE_SUBSCR','BINARY_OP', \
//        'LOAD_FAST_BORROW_LOAD_FAST_BORROW']]"
//   BUILD_LIST                       = 46
//   BUILD_MAP                        = 47
//   STORE_SUBSCR                     = 38
//   BINARY_OP                        = 44  (unchanged)
//   LOAD_FAST_BORROW_LOAD_FAST_BORROW = 87
//
// NB_SUBSCR oparg resolved from opcode._nb_ops (index 26):
//   python3.14 -c "import opcode; print([(i,e) for i,e in enumerate(opcode._nb_ops) if 'SUBSCR' in e[0]])"
//   NB_SUBSCR = 26
localparam logic [7:0] PY_OP_BUILD_LIST        = 8'd46;
localparam logic [7:0] PY_OP_BUILD_MAP         = 8'd47;
localparam logic [7:0] PY_OP_STORE_SUBSCR      = 8'd38;
localparam logic [7:0] PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW = 8'd87;
// BINARY_OP oparg for subscript read (x[k]); not a standalone opcode.
localparam logic [7:0] PY_NBARG_SUBSCR         = 8'd26;

// Internal-only memory opcodes. These are not part of the CPython 3.14 opcode
// space and are never emitted by preprocess.py; they exist so hand-written test
// streams can exercise the dmem datapath through the real MEM stage. The values
// are chosen above the CPython opcode range to avoid collisions.
localparam logic [7:0] PY_OP_MEM_LOAD_PTR     = 8'd200;
localparam logic [7:0] PY_OP_MEM_STORE_PTR    = 8'd201;

localparam logic [2:0] PY_MEM_NONE       = 3'd0;
localparam logic [2:0] PY_MEM_LOAD_FAST  = 3'd1;
localparam logic [2:0] PY_MEM_STORE_FAST = 3'd2;
localparam logic [2:0] PY_MEM_LOAD_CONST = 3'd3;
localparam logic [2:0] PY_MEM_LOAD_PTR   = 3'd4;
localparam logic [2:0] PY_MEM_STORE_PTR  = 3'd5;

// Entry accessors. Fixed to PYCORE_ENTRY_WIDTH so callers do not scatter slice
// indices through the RTL.
function automatic logic [PYCORE_TAG_WIDTH-1:0] pycore_get_tag(
    input logic [PYCORE_ENTRY_WIDTH-1:0] entry
);
    begin
        pycore_get_tag = entry[PYCORE_TAG_MSB:PYCORE_TAG_LSB];
    end
endfunction

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_get_val(
    input logic [PYCORE_ENTRY_WIDTH-1:0] entry
);
    begin
        pycore_get_val = entry[PYCORE_VAL_MSB:PYCORE_VAL_LSB];
    end
endfunction

function automatic logic [PYCORE_ENTRY_WIDTH-1:0] pycore_make_entry(
    input logic [PYCORE_TAG_WIDTH-1:0] tag,
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_make_entry = {tag, value};
    end
endfunction

// Build an INT entry from a 64-bit operand, sign-extending into value[127:64]
// per the documented 128-bit INT fast-path semantics.
function automatic logic [PYCORE_ENTRY_WIDTH-1:0] pycore_int_entry(
    input logic [63:0] value64
);
    begin
        pycore_int_entry = {PY_TAG_INT, {64{value64[63]}}, value64};
    end
endfunction

function automatic logic pycore_is_numeric_tag(input logic [3:0] tag);
    begin
        pycore_is_numeric_tag = (tag == PY_TAG_INT) || (tag == PY_TAG_FLOAT) || (tag == PY_TAG_BOOL);
    end
endfunction

function automatic logic pycore_is_string_tag(input logic [3:0] tag);
    begin
        pycore_is_string_tag = (tag == PY_TAG_SHORT_STR) || (tag == PY_TAG_LONG_STR);
    end
endfunction

// Traps on any tag that is not a directly computable numeric or string type.
function automatic logic pycore_is_trapping_tag(input logic [3:0] tag);
    begin
        pycore_is_trapping_tag = !pycore_is_numeric_tag(tag) && !pycore_is_string_tag(tag);
    end
endfunction

function automatic logic [3:0] pycore_short_str_size(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_short_str_size = value[PYCORE_SHORT_STR_SIZE_MSB:PYCORE_SHORT_STR_SIZE_LSB];
    end
endfunction

function automatic logic [119:0] pycore_short_str_payload(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_short_str_payload = value[PYCORE_SHORT_STR_DATA_MSB:PYCORE_SHORT_STR_DATA_LSB];
    end
endfunction

function automatic logic [7:0] pycore_short_str_byte(
    input logic [PYCORE_VAL_WIDTH-1:0] value,
    input int unsigned idx
);
    logic [119:0] payload;
    begin
        payload = pycore_short_str_payload(value);
        if (idx < PYCORE_SHORT_STR_MAX_BYTES) begin
            pycore_short_str_byte = payload[119-(idx*8)-:8];
        end else begin
            pycore_short_str_byte = 8'h00;
        end
    end
endfunction

function automatic logic [63:0] pycore_long_str_size(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_long_str_size = value[127:64];
    end
endfunction

function automatic logic [63:0] pycore_long_str_addr(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_long_str_addr = value[63:0];
    end
endfunction

function automatic logic [PYCORE_ENTRY_WIDTH-1:0] pycore_make_short_str_entry(
    input logic [3:0] size,
    input logic [119:0] payload
);
    begin
        pycore_make_short_str_entry = pycore_make_entry(
            PY_TAG_SHORT_STR,
            {size, payload, 4'b0000}
        );
    end
endfunction

function automatic logic [PYCORE_ENTRY_WIDTH-1:0] pycore_make_long_str_entry(
    input logic [63:0] size,
    input logic [63:0] addr
);
    begin
        pycore_make_long_str_entry = pycore_make_entry(PY_TAG_LONG_STR, {size, addr});
    end
endfunction

// -------------------------------------------------------------------------
// DICT in-dmem layout (all addresses 16-byte aligned):
//
//   base + 0                  : header { slot_count[63:0], used[63:0] }
//   base + 16*(1 + 4*i)       : slot[i] key   value[127:0]
//   base + 16*(2 + 4*i)       : slot[i] key   tag   {124'b0, key_tag[3:0]}
//   base + 16*(3 + 4*i)       : slot[i] value value[127:0]
//   base + 16*(4 + 4*i)       : slot[i] value tag   {124'b0, val_tag[3:0]}
//
// Slot stride = 4 * 16 = 64 bytes.
// Empty-bucket sentinel: key tag == PY_TAG_UNINIT (4'b0000).
// Slot count is always a power of two; probe mask = slot_count - 1.
// Hash function: key_val[63:0] & (slot_count - 1)  (INT and BOOL keys only).
// Unsupported key tags trap PY_TRAP_TYPE; key-not-found traps PY_TRAP_MEM_FAULT.
//
// Dict option: open-addressed linear probe with tombstone-free insert
// (tombstone deletion deferred; DELETE_SUBSCR not yet implemented).
// -------------------------------------------------------------------------
function automatic logic [31:0] pycore_dict_kval_addr(
    input logic [31:0] base, input logic [31:0] probe_idx
);
    begin
        // base + 16 + probe_idx * 64
        pycore_dict_kval_addr = base + 32'd16 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_ktag_addr(
    input logic [31:0] base, input logic [31:0] probe_idx
);
    begin
        pycore_dict_ktag_addr = base + 32'd32 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_vval_addr(
    input logic [31:0] base, input logic [31:0] probe_idx
);
    begin
        pycore_dict_vval_addr = base + 32'd48 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_vtag_addr(
    input logic [31:0] base, input logic [31:0] probe_idx
);
    begin
        pycore_dict_vtag_addr = base + 32'd64 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_alloc_bytes(
    input logic [31:0] slot_count
);
    begin
        // 16-byte header + slot_count * 64-byte slot
        pycore_dict_alloc_bytes = 32'd16 + (slot_count << 6);
    end
endfunction

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_dict_header(
    input logic [63:0] slot_count,
    input logic [63:0] used
);
    begin
        pycore_dict_header = {slot_count, used};
    end
endfunction

function automatic logic [63:0] pycore_dict_slot_count_from_hdr(
    input logic [PYCORE_VAL_WIDTH-1:0] header
);
    begin
        pycore_dict_slot_count_from_hdr = header[127:64];
    end
endfunction

// Minimum slot count = next_pow2(max(4, 2*n_pairs)) so max load ≤ 50%.
function automatic logic [31:0] pycore_dict_min_slots(
    input logic [6:0] n_pairs
);
    begin
        if      (n_pairs <= 7'd2)  pycore_dict_min_slots = 32'd4;
        else if (n_pairs <= 7'd4)  pycore_dict_min_slots = 32'd8;
        else if (n_pairs <= 7'd8)  pycore_dict_min_slots = 32'd16;
        else if (n_pairs <= 7'd16) pycore_dict_min_slots = 32'd32;
        else if (n_pairs <= 7'd32) pycore_dict_min_slots = 32'd64;
        else                       pycore_dict_min_slots = 32'd128;
    end
endfunction

// -------------------------------------------------------------------------
// Heap allocator address-space parameters.
//
// The object heap lives at the bottom of dmem, below the frame stack which
// starts at FRAME_STACK_BASE (0x2000).  PYCORE_HEAP_BASE is left at 0x0400
// to leave a 1 KB buffer at address 0 for any PTR-based user data.  The
// bump pointer starts at PYCORE_HEAP_BASE and grows upward; a trap is
// raised when it would exceed PYCORE_HEAP_LIMIT.
//
// Default memory map:
//   0x0000 – 0x03FF  (1 KB)  reserved / user PTR data
//   0x0400 – 0x1FFF  (7 KB)  container heap (this region)
//   0x2000 – 0x3FFF  (8 KB)  call-frame stack
// -------------------------------------------------------------------------
localparam logic [31:0] PYCORE_HEAP_BASE  = 32'h0000_0400;
localparam logic [31:0] PYCORE_HEAP_LIMIT = 32'h0000_2000;

// -------------------------------------------------------------------------
// LIST in-dmem layout (all addresses 16-byte aligned, 128-bit dmem slots):
//
//   base + 0                 : header  { capacity[63:0] , length[63:0] }
//   base + 16*(1 + 2*i)      : element[i] value[127:0]      (128-bit)
//   base + 16*(2 + 2*i)      : element[i] tag   {124'b0, tag[3:0]}
//
// Element stride = 32 bytes (2 slots).
// Total allocation = pycore_list_alloc_bytes(capacity) bytes.
//
// This encoding follows the convention that each 132-bit tagged entry
// { tag[3:0], value[127:0] } is split across two consecutive 128-bit
// dmem slots: the 128-bit value slot followed by a 128-bit tag slot
// (tag in bits [3:0], upper 124 bits zero).
//
// DICT: option B (interim) — BUILD_MAP / subscript / store on a DICT-tagged
// handle raise PY_TRAP_TYPE with a TODO comment.  A future PR will implement
// open-addressed linear-probe lookup over this same dmem port.
// -------------------------------------------------------------------------
function automatic logic [63:0] pycore_list_capacity(
    input logic [PYCORE_VAL_WIDTH-1:0] header
);
    begin
        pycore_list_capacity = header[127:64];
    end
endfunction

function automatic logic [63:0] pycore_list_length(
    input logic [PYCORE_VAL_WIDTH-1:0] header
);
    begin
        pycore_list_length = header[63:0];
    end
endfunction

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_list_header(
    input logic [63:0] capacity,
    input logic [63:0] length
);
    begin
        pycore_list_header = {capacity, length};
    end
endfunction

// Byte address of element i's VALUE slot within a list at base.
function automatic logic [31:0] pycore_list_val_addr(
    input logic [31:0] base,
    input logic [31:0] idx
);
    begin
        // base + 16 + idx*32
        pycore_list_val_addr = base + 32'd16 + (idx << 5);
    end
endfunction

// Byte address of element i's TAG slot within a list at base.
function automatic logic [31:0] pycore_list_tag_addr(
    input logic [31:0] base,
    input logic [31:0] idx
);
    begin
        // base + 32 + idx*32
        pycore_list_tag_addr = base + 32'd32 + (idx << 5);
    end
endfunction

// Total bytes to allocate for a list with the given capacity.
function automatic logic [31:0] pycore_list_alloc_bytes(
    input logic [31:0] capacity
);
    begin
        // 16 (header) + capacity * 32 (2 slots per element)
        pycore_list_alloc_bytes = 32'd16 + (capacity << 5);
    end
endfunction

`endif
