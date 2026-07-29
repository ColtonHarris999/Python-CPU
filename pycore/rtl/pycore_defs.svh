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
localparam int PYCORE_DMEM_BLOCK_COUNT = 16;   // 64 KB data memory
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
// Dict deleted-key sentinel. Reuses PY_TAG_DICT because dicts are mutable and
// cannot be hash keys — a key-slot tag of DICT is never a live key, so it is
// free to mean "tombstone" during open-addressed probe / insert.
localparam logic [3:0] PY_TAG_TOMBSTONE    = PY_TAG_DICT;
localparam logic [3:0] PY_TAG_CODE_OBJECT  = 4'b1100;
localparam logic [3:0] PY_TAG_FRAME_OBJECT = 4'b1101;
// PY_TAG_NULL: CPython self_or_null sentinel pushed for non-method calls
// (LOAD_GLOBAL with low bit set, or explicit PUSH_NULL). Formerly PY_TAG_UNUSED.
// Value field is zero. Traps in arithmetic/branch like UNINIT (covered by
// pycore_is_trapping_tag — not numeric, not string).
localparam logic [3:0] PY_TAG_NULL         = 4'b1110;
localparam logic [3:0] PY_TAG_NONE         = 4'b1111;

// -------------------------------------------------------------------------
// General heap-object kinds under PY_TAG_OBJECT (M1). The 4-bit tag space is
// full; OBJECT means "read ob_head for the kind" (CPython's PyObject model).
// -------------------------------------------------------------------------
localparam logic [31:0] PY_OBK_INSTANCE     = 32'd1;
localparam logic [31:0] PY_OBK_TYPE         = 32'd2;
localparam logic [31:0] PY_OBK_BOUND_METHOD = 32'd3;
localparam logic [31:0] PY_OBK_BUILTIN      = 32'd4;
localparam logic [31:0] PY_OBK_BYTEARRAY    = 32'd5;
localparam logic [31:0] PY_OBK_EXCEPTION    = 32'd6;

localparam int PYCORE_SHORT_STR_MAX_BYTES = 15;
localparam int PYCORE_SHORT_STR_SIZE_MSB  = 127;
localparam int PYCORE_SHORT_STR_SIZE_LSB  = 124;
localparam int PYCORE_SHORT_STR_DATA_MSB  = 123;
localparam int PYCORE_SHORT_STR_DATA_LSB  = 4;

localparam logic [1:0] PY_EXEC_INT   = 2'd0;
localparam logic [1:0] PY_EXEC_FLOAT = 2'd1;
localparam logic [1:0] PY_EXEC_BOOL  = 2'd2;
localparam logic [1:0] PY_EXEC_TRAP  = 2'd3;

localparam logic [1:0] PY_PROMOTE_NONE          = 2'd0;
localparam logic [1:0] PY_PROMOTE_INT_TO_FLOAT  = 2'd1;
localparam logic [1:0] PY_PROMOTE_BOOL_TO_INT   = 2'd2;
localparam logic [1:0] PY_PROMOTE_BOOL_TO_FLOAT = 2'd3;

localparam logic [4:0] PY_TRAP_NONE = 5'd0;
localparam logic [4:0] PY_TRAP_TYPE = 5'd1;
localparam logic [4:0] PY_TRAP_STACK = 5'd2;
localparam logic [4:0] PY_TRAP_DIV_ZERO = 5'd3;
localparam logic [4:0] PY_TRAP_FPU_EXCEPTION = 5'd4;
localparam logic [4:0] PY_TRAP_ILLEGAL_OPCODE = 5'd5;
localparam logic [4:0] PY_TRAP_CALL_FILTER = 5'd6;
localparam logic [4:0] PY_TRAP_MEM_FAULT = 5'd7;
localparam logic [4:0] PY_TRAP_ADDR_ALIGN = 5'd8;
// PY_TRAP_LIST_GROW: raised by CONT_LIST_APPEND when the target list is at
// capacity (length == capacity).  Recoverable in principle (Phase C hands it
// to the excore, which grows the buffer and completes the append); Phase A
// has no excore, so this trap is fatal like any other and is reported
// through the same halt path.  Raised before any RF/heap commit (see
// pycore_trap_recoverable below and CONT_LIST_APPEND's CP_HDR phase).
localparam logic [4:0] PY_TRAP_LIST_GROW = 5'd9;
// PY_TRAP_LIST_EXTEND: raised by CONT_LIST_EXTEND for every non-empty
// LIST/TUPLE source (empty source is a no-op pop on pycore). Recoverable —
// the excore grows-to-fit when needed (or copies in place when capacity
// already suffices) and completes the extend. Raised before any commit.
localparam logic [4:0] PY_TRAP_LIST_EXTEND = 5'd10;
// PY_TRAP_DICT_GROW: raised before a new-key dict insert when load ≥ 2/3
// (or table empty). Recoverable — excore reallocates the relocatable table,
// rehashes, and completes STORE. Handle address stays stable (layout v2).
localparam logic [4:0] PY_TRAP_DICT_GROW = 5'd11;
// PY_TRAP_LIST_DELETE: list DELETE_SUBSCR element shift (excore; part 2).
// Code 12 formerly DICT_COLLISION — dict/set rich equality now runs on pycore.
localparam logic [4:0] PY_TRAP_LIST_DELETE = 5'd12;
// PY_TRAP_SET_GROW: SET_ADD at load ≥ 2/3 (or empty table). Recoverable —
// excore reallocates the element table, rehashes, inserts, COMPLETED pop=1.
localparam logic [4:0] PY_TRAP_SET_GROW = 5'd13;
// PY_TRAP_SET_UPDATE: always raised by SET_UPDATE (bulk merge). Recoverable —
// excore grow-to-fit + insert from LIST/TUPLE/SET source, COMPLETED pop=1.
localparam logic [4:0] PY_TRAP_SET_UPDATE = 5'd14;
// PY_TRAP_ATTR_ERROR: attribute missing after instance __dict__ + MRO walk
// (LOAD_ATTR / DELETE_ATTR), or equivalent AttributeError. Fatal — no excore
// recovery. Raised before any RF/heap/dmem commit.
localparam logic [4:0] PY_TRAP_ATTR_ERROR = 5'd15;

// Trap taxonomy: does a given trap code represent a condition the excore can
// service and hand control back to pycore for (Phase C), as opposed to a
// hard fatal condition that always halts?
function automatic logic pycore_trap_recoverable(input logic [4:0] code);
    begin
        pycore_trap_recoverable = (code == PY_TRAP_LIST_GROW) ||
                                  (code == PY_TRAP_LIST_EXTEND) ||
                                  (code == PY_TRAP_DICT_GROW) ||
                                  (code == PY_TRAP_LIST_DELETE) ||
                                  (code == PY_TRAP_SET_GROW) ||
                                  (code == PY_TRAP_SET_UPDATE);
    end
endfunction

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

// -------------------------------------------------------------------------
// Opcode numbers — resolved from the running CPython 3.14.6 interpreter
// (opcode.opmap). Do NOT hand-transcribe from memory; 3.11→3.14 renumbered
// many opcodes (CALL, PUSH_NULL, jumps, EXTENDED_ARG, COMPARE_OP, POP_TOP).
//
//   python3.14 -c "import opcode; print({n:opcode.opmap[n] for n in [...]})"
// -------------------------------------------------------------------------
localparam logic [7:0] PY_OP_CACHE            = 8'd0;
localparam logic [7:0] PY_OP_END_FOR          = 8'd9;
localparam logic [7:0] PY_OP_GET_ITER         = 8'd16;
localparam logic [7:0] PY_OP_MAKE_FUNCTION    = 8'd23;
localparam logic [7:0] PY_OP_NOP              = 8'd27;
localparam logic [7:0] PY_OP_NOT_TAKEN        = 8'd28;
localparam logic [7:0] PY_OP_POP_ITER         = 8'd30;
localparam logic [7:0] PY_OP_POP_TOP          = 8'd31;
localparam logic [7:0] PY_OP_PUSH_NULL        = 8'd33;
localparam logic [7:0] PY_OP_RETURN_VALUE     = 8'd35;
localparam logic [7:0] PY_OP_STORE_SUBSCR     = 8'd38;
localparam logic [7:0] PY_OP_TO_BOOL          = 8'd39;
// UNARY_INVERT / UNARY_NEGATIVE — resolved from CPython 3.14.6 opmap:
//   python3.14 -c "import opcode; print(opcode.opmap['UNARY_INVERT'],
//                                       opcode.opmap['UNARY_NEGATIVE'])"
//   -> 40, 41
localparam logic [7:0] PY_OP_UNARY_INVERT     = 8'd40;
localparam logic [7:0] PY_OP_UNARY_NEGATIVE   = 8'd41;
localparam logic [7:0] PY_OP_UNARY_NOT        = 8'd42;
localparam logic [7:0] PY_OP_BINARY_OP        = 8'd44;
localparam logic [7:0] PY_OP_BUILD_LIST       = 8'd46;
localparam logic [7:0] PY_OP_BUILD_MAP        = 8'd47;
// BUILD_SET / SET_ADD / SET_UPDATE — CPython 3.14.6 opmap:
//   python3.14 -c "import opcode; print(opcode.opmap['BUILD_SET'],
//                                       opcode.opmap['SET_ADD'],
//                                       opcode.opmap['SET_UPDATE'])"
//   -> 48, 107, 109
localparam logic [7:0] PY_OP_BUILD_SET        = 8'd48;
localparam logic [7:0] PY_OP_BUILD_TUPLE      = 8'd51;
localparam logic [7:0] PY_OP_CALL             = 8'd52;
localparam logic [7:0] PY_OP_COMPARE_OP       = 8'd56;
localparam logic [7:0] PY_OP_COPY             = 8'd59;
localparam logic [7:0] PY_OP_DELETE_FAST      = 8'd63;
localparam logic [7:0] PY_OP_EXTENDED_ARG     = 8'd69;
localparam logic [7:0] PY_OP_FOR_ITER         = 8'd70;
localparam logic [7:0] PY_OP_IS_OP            = 8'd74;
localparam logic [7:0] PY_OP_JUMP_BACKWARD    = 8'd75;
localparam logic [7:0] PY_OP_JUMP_FORWARD     = 8'd77;
localparam logic [7:0] PY_OP_LOAD_CONST       = 8'd82;
localparam logic [7:0] PY_OP_LOAD_FAST        = 8'd84;
localparam logic [7:0] PY_OP_LOAD_FAST_AND_CLEAR = 8'd85;
localparam logic [7:0] PY_OP_LOAD_FAST_BORROW = 8'd86;
localparam logic [7:0] PY_OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW = 8'd87;
localparam logic [7:0] PY_OP_LOAD_FAST_CHECK = 8'd88;
localparam logic [7:0] PY_OP_LOAD_FAST_LOAD_FAST = 8'd89;
localparam logic [7:0] PY_OP_LOAD_GLOBAL      = 8'd92;
localparam logic [7:0] PY_OP_LOAD_NAME        = 8'd93;
localparam logic [7:0] PY_OP_LOAD_SMALL_INT   = 8'd94;
localparam logic [7:0] PY_OP_POP_JUMP_IF_FALSE    = 8'd100;
localparam logic [7:0] PY_OP_POP_JUMP_IF_NONE     = 8'd101;
localparam logic [7:0] PY_OP_POP_JUMP_IF_NOT_NONE = 8'd102;
localparam logic [7:0] PY_OP_POP_JUMP_IF_TRUE     = 8'd103;
localparam logic [7:0] PY_OP_SET_ADD          = 8'd107;
localparam logic [7:0] PY_OP_SET_UPDATE       = 8'd109;
localparam logic [7:0] PY_OP_STORE_FAST       = 8'd112;
localparam logic [7:0] PY_OP_STORE_FAST_LOAD_FAST  = 8'd113;
localparam logic [7:0] PY_OP_STORE_FAST_STORE_FAST = 8'd114;
localparam logic [7:0] PY_OP_STORE_GLOBAL     = 8'd115;
localparam logic [7:0] PY_OP_STORE_NAME       = 8'd116;
localparam logic [7:0] PY_OP_SWAP             = 8'd117;
// UNPACK_SEQUENCE — resolved from CPython 3.14.6 opmap:
//   python3.14 -c "import opcode; print(opcode.opmap['UNPACK_SEQUENCE'])"
//   -> 119
localparam logic [7:0] PY_OP_UNPACK_SEQUENCE  = 8'd119;
localparam logic [7:0] PY_OP_RESUME           = 8'd128;

// LIST_APPEND: resolved from opcode.opmap at tool-import time (see
// pycore/tools/image_from_source.py / preprocess.py); mirrored here.
//   python3.14 -c "import opcode; print(opcode.opmap['LIST_APPEND'])"
//   -> 78
localparam logic [7:0] PY_OP_LIST_APPEND      = 8'd78;

// LIST_EXTEND: resolved from opcode.opmap at tool-import time.
//   python3.14 -c "import opcode; print(opcode.opmap['LIST_EXTEND'])"
//   -> 79
localparam logic [7:0] PY_OP_LIST_EXTEND      = 8'd79;

// DELETE_SUBSCR / CONTAINS_OP — CPython 3.14.6 opmap:
//   python3.14 -c "import opcode; print(opcode.opmap['DELETE_SUBSCR'],
//                                       opcode.opmap['CONTAINS_OP'])"
//   -> 8, 57
localparam logic [7:0] PY_OP_DELETE_SUBSCR    = 8'd8;
localparam logic [7:0] PY_OP_CONTAINS_OP      = 8'd57;

// LOAD_ATTR / STORE_ATTR / DELETE_ATTR — CPython 3.14.6 opmap:
//   python3.14 -c "import opcode; print(opcode.opmap['LOAD_ATTR'],
//                                       opcode.opmap['STORE_ATTR'],
//                                       opcode.opmap['DELETE_ATTR'])"
//   -> 80, 110, 61
// LOAD_ATTR: namei = oparg >> 1; method_flag = oparg & 1 (push [func,self]
//   or [attr,NULL] without allocating a bound method on the hot path).
// STORE_ATTR / DELETE_ATTR: namei = oparg (no low-bit encoding).
localparam logic [7:0] PY_OP_LOAD_ATTR        = 8'd80;
localparam logic [7:0] PY_OP_STORE_ATTR       = 8'd110;
localparam logic [7:0] PY_OP_DELETE_ATTR      = 8'd61;

// -------------------------------------------------------------------------
// DELETE_SUBSCR stack convention — verified 2026-07-21 against CPython 3.14.6:
//   del a[i]  →  LOAD a; LOAD i; DELETE_SUBSCR
//   container at RF[tos-2], key at RF[tos-1]; both popped. List: shift-down
//   in place (capacity unchanged; mid-list → LIST_DELETE/excore). Tuple:
//   TYPE trap. Dict: tombstone write on pycore.
// -------------------------------------------------------------------------
// CONTAINS_OP stack convention — verified 2026-07-21:
//   x in a / x not in a  →  LOAD x; LOAD a; CONTAINS_OP oparg
//   needle at RF[tos-2], container at RF[tos-1]; result BOOL at tos-2, pop 1.
//   oparg[0]=0 → in; oparg[0]=1 → not in. LIST/TUPLE linear scan; DICT probe.
// -------------------------------------------------------------------------

// LIST_APPEND stack convention — verified 2026-07-15 against CPython 3.14.6:
//
//   python3.14 -c "
//   import dis
//   dis.dis(compile('[x for x in y]', '<p>', 'eval'))"
//
//   ...
//       L2:     FOR_ITER                 4 (to L3)
//               STORE_FAST_LOAD_FAST     0 (x, x)
//               LIST_APPEND              2
//               JUMP_BACKWARD            6 (to L2)
//
// LIST_APPEND's oparg matches CPython's documented bytecodes.c signature
// `LIST_APPEND(list, unused[oparg-1], v -- list, unused[oparg-1])`: the
// list handle sits (oparg+1) slots below TOS (list, then oparg-1 "unused"
// loop-nesting slots, then the appended value v at TOS), and only v is
// popped.  In RF terms with tos one-past-top:
//   element (popped) : RF[tos-1]
//   list handle       : RF[tos-1-arg]
// Confirmed empirically for oparg=2 above (list 3 slots below TOS).
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// LIST_EXTEND stack convention — verified 2026-07-20 against CPython 3.14.6:
//
//   python3.14 -c "
//   import dis
//   dis.dis(compile('[*a, *b]', '<p>', 'eval'))"
//
//   BUILD_LIST               0
//   LOAD_NAME                0 (a)
//   LIST_EXTEND              1
//   LOAD_NAME                1 (b)
//   LIST_EXTEND              1
//
// Same shape as LIST_APPEND: iterable at TOS (popped), list handle at
// RF[tos-1-arg].  oparg=1 in every unpack form probed.  Only LIST and
// TUPLE sources are implemented (TYPE trap otherwise — no iterator
// protocol yet).  Empty source is a no-op pop.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// SET_ADD stack convention — same shape as LIST_APPEND (CPython 3.14):
//   set handle at RF[tos-1-arg], element at RF[tos-1]; only element popped.
// SET_UPDATE: set at RF[tos-1-arg], iterable at TOS; always excore trap 14.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// Verified CPython 3.14.6 conventions (probes recorded 2026-07-12):
//
// LOAD_GLOBAL oparg (from bytecodes.c macro LOAD_GLOBAL):
//   namei = oparg >> 1
//   if (oparg & 1): after pushing the global, also push NULL
//   Probe:
//     def f(x): return x
//     def g(): return f(7)
//     # dis: LOAD_GLOBAL 1 (f + NULL)  → arg=1, namei=0, null_bit=1
//   Stack after LOAD_GLOBAL(f+NULL): [callable, NULL]  (NULL at TOS)
//   Order: _LOAD_GLOBAL then _PUSH_NULL_CONDITIONAL (NULL pushed AFTER global).
//
// LOAD_NAME / PUSH_NULL (module-level call):
//     LOAD_NAME managed_entry; PUSH_NULL; CALL 0
//   Stack before CALL: [callable, NULL]  (same layout as LOAD_GLOBAL+NULL)
//
// CALL stack (from bytecodes.c _DO_CALL / _SPECIALIZE_CALL):
//   (callable, self_or_null, args[oparg] -- res)
//   Bottom→top: callable, self_or_null, arg1..argN
//   RF: callable @ tos-argc-2, sentinel @ tos-argc-1, args @ tos-argc .. tos-1
//   Non-method calls require sentinel tag == PY_TAG_NULL.
//
// MAKE_FUNCTION: (codeobj -- func), oparg unused/None, stack effect 0.
//   Interim model: function ≡ code object handle (no defaults/closures).
//
// COMPARE_OP: comparison selector is oparg >> 5  (3.13+ packed encoding).
//   Probe: < →2, <= →42, == →72, != →103, > →132, >= →172  (>>5 → 0..5)
//
// Relative jumps (slot index == code-unit index; CACHE units count):
//   forward:  target = pc + 1 + n_cache + arg
//   backward: target = pc + 1 + n_cache - arg
//   n_cache from opcode._inline_cache_entries (name-keyed):
//     POP_JUMP_IF_{TRUE,FALSE,NONE,NOT_NONE}=1, JUMP_BACKWARD=1, JUMP_FORWARD=0
// -------------------------------------------------------------------------

// BINARY_OP oparg for subscript read (x[k]); not a standalone opcode.
//   python3.14 -c "import opcode; print([(i,e) for i,e in enumerate(opcode._nb_ops) if 'SUBSCR' in e[0]])"
localparam logic [7:0] PY_NBARG_SUBSCR         = 8'd26;

// Inline-cache unit counts for relative-jump target computation (3.14.6).
localparam logic [7:0] PY_CACHE_JUMP_FORWARD         = 8'd0;
localparam logic [7:0] PY_CACHE_JUMP_BACKWARD        = 8'd1;
localparam logic [7:0] PY_CACHE_FOR_ITER              = 8'd1;
localparam logic [7:0] PY_CACHE_POP_JUMP_IF_FALSE    = 8'd1;
localparam logic [7:0] PY_CACHE_POP_JUMP_IF_NONE     = 8'd1;
localparam logic [7:0] PY_CACHE_POP_JUMP_IF_NOT_NONE = 8'd1;
localparam logic [7:0] PY_CACHE_POP_JUMP_IF_TRUE     = 8'd1;
// ATTR inline-cache unit counts (fetch skips CACHE by opcode; kept for
// documentation / jump math parity with opcode._inline_cache_entries).
localparam logic [7:0] PY_CACHE_LOAD_ATTR             = 8'd9;
localparam logic [7:0] PY_CACHE_STORE_ATTR            = 8'd4;
// UNPACK_SEQUENCE inline-cache unit count (fetch skips CACHE by opcode 0;
// kept for documentation / jump-math parity with _inline_cache_entries).
//   python3.14 -c "import dis; print(dis._inline_cache_entries['UNPACK_SEQUENCE'])"
//   -> 1
localparam logic [7:0] PY_CACHE_UNPACK_SEQUENCE       = 8'd1;

// Internal-only memory opcodes. These are not part of the CPython 3.14 opcode
// space and are never emitted by the image builder; they exist so hand-written
// test streams can exercise the dmem datapath through the real MEM stage.
localparam logic [7:0] PY_OP_MEM_LOAD_PTR     = 8'd200;
localparam logic [7:0] PY_OP_MEM_STORE_PTR    = 8'd201;

localparam logic [2:0] PY_MEM_NONE       = 3'd0;
localparam logic [2:0] PY_MEM_LOAD_FAST  = 3'd1;
localparam logic [2:0] PY_MEM_STORE_FAST = 3'd2;
localparam logic [2:0] PY_MEM_LOAD_PTR   = 3'd3;
localparam logic [2:0] PY_MEM_STORE_PTR  = 3'd4;

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

// Internal hybrid iterator carried in a PY_TAG_PTR entry.  PTR is not
// emitted by the image serializer and is otherwise reserved in the current
// hardware, so the magic byte distinguishes iterator state from malformed
// or future pointer payloads.
//
//   [127:120] magic (8'hA5)
//   [119:116] kind
//   [115:96]  kind auxiliary data
//   [95:64]   next index
//   [63:32]   per-kind size / stop
//   [31:0]    per-kind object / buffer address
//
// Current layouts:
//   LIST:      index, size=0, aux=0, addr=list object
//   TUPLE:     index, size=len, aux=0, addr=element buffer
// Reserved sockets:
//   RANGE:     index=current, size=stop, aux=step, addr=0
//   STR:       index, size=len, addr=string descriptor / buffer
//   HEAP_ITER: addr=heap iterator object; remaining fields are object-owned
localparam logic [7:0] PY_ITER_MAGIC = 8'hA5;
localparam logic [3:0] PY_ITER_KIND_LIST      = 4'd0;
localparam logic [3:0] PY_ITER_KIND_TUPLE     = 4'd1;
localparam logic [3:0] PY_ITER_KIND_RANGE     = 4'd2;
localparam logic [3:0] PY_ITER_KIND_STR       = 4'd3;
localparam logic [3:0] PY_ITER_KIND_HEAP_ITER = 4'd4;

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_iter_value(
    input logic [3:0] kind,
    input logic [31:0] index,
    input logic [31:0] size,
    input logic [31:0] addr
);
    begin
        pycore_iter_value = {PY_ITER_MAGIC, kind, 20'b0, index, size, addr};
    end
endfunction

function automatic logic pycore_iter_valid(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    logic common_valid;
    begin
        common_valid = (value[127:120] == PY_ITER_MAGIC) &&
                       (value[115:96] == 20'b0) &&
                       (value[3:0] == 4'b0);
        unique case (value[119:116])
            PY_ITER_KIND_LIST:
                pycore_iter_valid = common_valid &&
                                    (value[63:32] == 32'b0);
            PY_ITER_KIND_TUPLE:
                pycore_iter_valid = common_valid;
            // Reserved kinds remain invalid until both GET_ITER and FOR_ITER
            // implementations land.
            default:
                pycore_iter_valid = 1'b0;
        endcase
    end
endfunction

function automatic logic [3:0] pycore_iter_kind(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_iter_kind = value[119:116];
    end
endfunction

function automatic logic [31:0] pycore_iter_index(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_iter_index = value[95:64];
    end
endfunction

function automatic logic [31:0] pycore_iter_size(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_iter_size = value[63:32];
    end
endfunction

function automatic logic [31:0] pycore_iter_addr(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_iter_addr = value[31:0];
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
// DICT in-dmem layout v2 (all addresses 16-byte aligned):
//
// Stable 32-byte object (handle never moves across grows) + relocatable
// open-addressed table (like list obj / ob_item):
//
//   obj + 0  : header { slot_count[63:0], used[63:0] }
//   obj + 16 : { 64'd0, table_ptr[63:0] }   // 0 if slot_count==0
//
//   table + i*64 + 0  : key   value[127:0]
//   table + i*64 + 16 : key   tag   {124'b0, key_tag[3:0]}
//   table + i*64 + 32 : value value[127:0]
//   table + i*64 + 48 : value tag   {124'b0, val_tag[3:0]}
//
// Slot stride = 64 bytes. Empty: key tag == PY_TAG_UNINIT.
// Deleted: key tag == PY_TAG_TOMBSTONE (== PY_TAG_DICT; skip during probe).
// Dicts cannot be keys, so DICT in a key slot unambiguously means tombstone.
// Slot count is a power of two (or 0); probe mask = slot_count - 1.
//
// BUILD_MAP may allocate object+table contiguously
// (pycore_dict_alloc_bytes); grow relocates the table only and updates
// table_ptr. Address helpers take the TABLE base, not the object base.
//
// Hash: pycore_dict_key_hash(tag, value) & (slot_count - 1).
// Supported key tags: INT, BOOL, FLOAT, SHORT_STR, LONG_STR.
// Unsupported key tags trap PY_TRAP_TYPE.
// Load ≥ 2/3 before new-key insert → PY_TRAP_DICT_GROW.
// Probe equality (same-tag + INT/BOOL/FLOAT rich) → pycore_dict_key_rich_eq.
// -------------------------------------------------------------------------

// 32-bit key hash; caller masks with (slot_count - 1).
// INT: CPython -1 → -2; else value[31:0].
// BOOL: 0/1 from value[0].
// FLOAT: integer-valued / ±0 match int hashes; NaN/Inf/non-int → bit mix.
// SHORT_STR: XOR of four 32-bit words. LONG_STR: low32(addr) ^ low32(size).
function automatic logic [31:0] pycore_dict_key_hash(
    input logic [3:0]                    tag,
    input logic [PYCORE_VAL_WIDTH-1:0]   value
);
    logic        f_sign;
    logic [10:0] f_exp;
    logic [51:0] f_frac;
    logic [10:0] f_uexp;
    logic [51:0] f_frac_mask;
    logic [52:0] f_sig;
    logic [63:0] f_mag;
    logic        f_is_int;
    begin
        f_sign      = value[63];
        f_exp       = value[62:52];
        f_frac      = value[51:0];
        f_uexp      = f_exp - 11'd1023;
        f_sig       = {1'b1, f_frac};
        f_frac_mask = 52'd0;
        f_mag       = 64'd0;
        f_is_int    = 1'b0;

        unique case (tag)
            PY_TAG_INT: begin
                // CPython: hash(-1) == -2
                if (value[63:0] == 64'hFFFFFFFFFFFFFFFF)
                    pycore_dict_key_hash = 32'hFFFFFFFE;
                else
                    pycore_dict_key_hash = value[31:0];
            end
            PY_TAG_BOOL:
                pycore_dict_key_hash = {31'b0, value[0]};
            PY_TAG_FLOAT: begin
                // value[63:0] = IEEE754 binary64
                if (f_exp == 11'h7FF) begin
                    // NaN / Inf — bit-mix; excore handles rich eq
                    pycore_dict_key_hash = value[31:0] ^ value[63:32];
                end else if ((f_exp == 11'd0) && (f_frac == 52'd0)) begin
                    // ±0.0 → 0
                    pycore_dict_key_hash = 32'd0;
                end else if (f_exp < 11'd1023) begin
                    // |x| < 1 (incl. subnormals): not integer-valued
                    pycore_dict_key_hash = value[31:0] ^ value[63:32];
                end else if (f_uexp >= 11'd63) begin
                    // Magnitude does not fit in signed 64-bit int
                    pycore_dict_key_hash = value[31:0] ^ value[63:32];
                end else begin
                    if (f_uexp < 11'd52) begin
                        f_frac_mask = (52'h1 << (11'd52 - f_uexp)) - 52'h1;
                        f_is_int    = ((f_frac & f_frac_mask) == 52'd0);
                        f_mag       = {11'b0, f_sig} >> (11'd52 - f_uexp);
                    end else begin
                        f_is_int = 1'b1;
                        f_mag    = {11'b0, f_sig} << (f_uexp - 11'd52);
                    end
                    if (!f_is_int)
                        pycore_dict_key_hash = value[31:0] ^ value[63:32];
                    else if (!f_sign)
                        pycore_dict_key_hash = f_mag[31:0];
                    else if (f_mag == 64'd1)
                        pycore_dict_key_hash = 32'hFFFFFFFE; // hash(-1.0) == -2
                    else begin
                        // Negate then take low 32 (part-select needs a primary).
                        f_mag = -f_mag;
                        pycore_dict_key_hash = f_mag[31:0];
                    end
                end
            end
            PY_TAG_SHORT_STR:
                pycore_dict_key_hash = value[127:96] ^ value[95:64]
                                     ^ value[63:32]  ^ value[31:0];
            PY_TAG_LONG_STR:
                // value = {size[63:0], addr[63:0]}
                pycore_dict_key_hash = value[31:0] ^ value[95:64];
            default:
                pycore_dict_key_hash = value[31:0];
        endcase
    end
endfunction

function automatic logic pycore_dict_key_tag_ok(input logic [3:0] tag);
    begin
        pycore_dict_key_tag_ok = (tag == PY_TAG_INT) || (tag == PY_TAG_BOOL)
                              || (tag == PY_TAG_FLOAT)
                              || (tag == PY_TAG_SHORT_STR)
                              || (tag == PY_TAG_LONG_STR);
    end
endfunction

// Try to interpret a FLOAT value as a signed 64-bit integer.
// ok=1 and out=int when integer-valued (incl. ±0.0); else ok=0.
function automatic logic pycore_float_as_int64(
    input  logic [PYCORE_VAL_WIDTH-1:0] value,
    output logic [63:0]                 out_int
);
    logic        f_sign;
    logic [10:0] f_exp;
    logic [51:0] f_frac;
    logic [10:0] f_uexp;
    logic [51:0] f_frac_mask;
    logic [52:0] f_sig;
    logic [63:0] f_mag;
    logic        f_is_int;
    begin
        f_sign      = value[63];
        f_exp       = value[62:52];
        f_frac      = value[51:0];
        f_uexp      = f_exp - 11'd1023;
        f_sig       = {1'b1, f_frac};
        f_frac_mask = 52'd0;
        f_mag       = 64'd0;
        f_is_int    = 1'b0;
        out_int     = 64'd0;
        pycore_float_as_int64 = 1'b0;

        if (f_exp == 11'h7FF) begin
            // NaN / Inf — not integer-valued
        end else if ((f_exp == 11'd0) && (f_frac == 52'd0)) begin
            out_int = 64'd0;
            pycore_float_as_int64 = 1'b1;
        end else if (f_exp < 11'd1023) begin
            // |x| < 1
        end else if (f_uexp >= 11'd63) begin
            // Does not fit in signed 64-bit int
        end else begin
            if (f_uexp < 11'd52) begin
                f_frac_mask = (52'h1 << (11'd52 - f_uexp)) - 52'h1;
                f_is_int    = ((f_frac & f_frac_mask) == 52'd0);
                f_mag       = {11'b0, f_sig} >> (11'd52 - f_uexp);
            end else begin
                f_is_int = 1'b1;
                f_mag    = {11'b0, f_sig} << (f_uexp - 11'd52);
            end
            if (f_is_int) begin
                out_int = f_sign ? (~f_mag + 64'd1) : f_mag;
                pycore_float_as_int64 = 1'b1;
            end
        end
    end
endfunction

// Dict/set key (element) rich equality for open-addressing probes.
// INT/BOOL/FLOAT: True==1, 1.0==1, False==0 via integer normalization;
// non-integer FLOAT compares bit-exact only when both tags are FLOAT.
// Same-tag SHORT_STR/LONG_STR: full 128-bit value compare. Else false.
function automatic logic pycore_dict_key_rich_eq(
    input logic [3:0]                  tag_a,
    input logic [PYCORE_VAL_WIDTH-1:0] val_a,
    input logic [3:0]                  tag_b,
    input logic [PYCORE_VAL_WIDTH-1:0] val_b
);
    logic        a_ok, b_ok;
    logic [63:0] a_i, b_i;
    begin
        a_ok = 1'b0;
        b_ok = 1'b0;
        a_i  = 64'd0;
        b_i  = 64'd0;

        if (pycore_is_numeric_tag(tag_a) && pycore_is_numeric_tag(tag_b)) begin
            if (tag_a == PY_TAG_INT) begin
                a_ok = 1'b1;
                a_i  = val_a[63:0];
            end else if (tag_a == PY_TAG_BOOL) begin
                a_ok = 1'b1;
                a_i  = {63'b0, val_a[0]};
            end else begin
                a_ok = pycore_float_as_int64(val_a, a_i);
            end

            if (tag_b == PY_TAG_INT) begin
                b_ok = 1'b1;
                b_i  = val_b[63:0];
            end else if (tag_b == PY_TAG_BOOL) begin
                b_ok = 1'b1;
                b_i  = {63'b0, val_b[0]};
            end else begin
                b_ok = pycore_float_as_int64(val_b, b_i);
            end

            if (a_ok && b_ok)
                pycore_dict_key_rich_eq = (a_i == b_i);
            else if ((tag_a == PY_TAG_FLOAT) && (tag_b == PY_TAG_FLOAT))
                pycore_dict_key_rich_eq = (val_a == val_b);
            else
                pycore_dict_key_rich_eq = 1'b0;
        end else if ((tag_a == tag_b) &&
                     ((tag_a == PY_TAG_SHORT_STR) || (tag_a == PY_TAG_LONG_STR))) begin
            pycore_dict_key_rich_eq = (val_a == val_b);
        end else begin
            pycore_dict_key_rich_eq = 1'b0;
        end
    end
endfunction

// True when a dict key-slot tag is a deleted-entry sentinel.
// PY_TAG_TOMBSTONE == PY_TAG_DICT (dicts are not valid keys).
function automatic logic pycore_dict_tombstone(input logic [3:0] tag);
    begin
        pycore_dict_tombstone = (tag == PY_TAG_TOMBSTONE);
    end
endfunction

// Load factor check before a new-key insert: empty table, ≥ 2/3 full, or
// would leave no empty slot for probe termination.
function automatic logic pycore_dict_needs_grow(
    input logic [63:0] used,
    input logic [63:0] slot_count
);
    begin
        pycore_dict_needs_grow =
            (slot_count == 64'd0) ||
            ((used * 64'd3) >= (slot_count * 64'd2)) ||
            ((used + 64'd1) >= slot_count);
    end
endfunction

// Element equality for CONTAINS_OP (list/tuple scan and dict key match).
// INT/BOOL cross-compare as integers (True==1 / False==0), matching CPython.
// Same-tag NONE is always equal. All other same-tag pairs compare the full
// 128-bit value field (FLOAT bit-exact; SHORT_STR/LONG_STR; LIST/DICT/TUPLE
// handles — identity via equal descriptors).
function automatic logic pycore_elem_eq(
    input logic [3:0]               tag_a,
    input logic [PYCORE_VAL_WIDTH-1:0] val_a,
    input logic [3:0]               tag_b,
    input logic [PYCORE_VAL_WIDTH-1:0] val_b
);
    logic [63:0] ia, ib;
    begin
        if (((tag_a == PY_TAG_INT) || (tag_a == PY_TAG_BOOL)) &&
            ((tag_b == PY_TAG_INT) || (tag_b == PY_TAG_BOOL))) begin
            ia = (tag_a == PY_TAG_BOOL) ? {63'b0, val_a[0]} : val_a[63:0];
            ib = (tag_b == PY_TAG_BOOL) ? {63'b0, val_b[0]} : val_b[63:0];
            pycore_elem_eq = (ia == ib);
        end else if (tag_a != tag_b) begin
            pycore_elem_eq = 1'b0;
        end else if (tag_a == PY_TAG_NONE) begin
            pycore_elem_eq = 1'b1;
        end else begin
            pycore_elem_eq = (val_a == val_b);
        end
    end
endfunction

// Slot address helpers — `tbl` is the relocatable table base (obj.table_ptr),
// not the dict object address. (Named `tbl` because `table` is an SV keyword.)
function automatic logic [31:0] pycore_dict_kval_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + probe_idx * 64
        pycore_dict_kval_addr = tbl + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_ktag_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + 16 + probe_idx * 64
        pycore_dict_ktag_addr = tbl + 32'd16 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_vval_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + 32 + probe_idx * 64
        pycore_dict_vval_addr = tbl + 32'd32 + (probe_idx << 6);
    end
endfunction

function automatic logic [31:0] pycore_dict_vtag_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + 48 + probe_idx * 64
        pycore_dict_vtag_addr = tbl + 32'd48 + (probe_idx << 6);
    end
endfunction

// Byte address of the dict object's table_ptr slot.
function automatic logic [31:0] pycore_dict_table_ptr_addr(
    input logic [31:0] obj_addr
);
    begin
        pycore_dict_table_ptr_addr = obj_addr + 32'd16;
    end
endfunction

function automatic logic [31:0] pycore_dict_alloc_bytes(
    input logic [31:0] slot_count
);
    begin
        // Contiguous BUILD_MAP layout: 32-byte object + slot_count * 64-byte table.
        // Grow may relocate the table alone (object address stays stable).
        pycore_dict_alloc_bytes = 32'd32 + (slot_count << 6);
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

function automatic logic [63:0] pycore_dict_used_from_hdr(
    input logic [PYCORE_VAL_WIDTH-1:0] header
);
    begin
        pycore_dict_used_from_hdr = header[63:0];
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
// SET in-dmem layout — element-only open addressing (see set_excore.md).
//
//   obj+0  : header { slot_count[63:0], used[63:0] }  (same as dict)
//   obj+16 : { 64'd0, table_ptr[63:0] }
//
//   table + i*32 + 0  : element value
//   table + i*32 + 16 : element tag   // UNINIT=empty; TOMBSTONE=DICT=9
//
// Handle: PY_TAG_SET + object address. Reuses dict key hash / tag_ok /
// rich_eq / tombstone / needs_grow helpers for elements.
// -------------------------------------------------------------------------
function automatic logic [31:0] pycore_set_val_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + probe_idx * 32
        pycore_set_val_addr = tbl + (probe_idx << 5);
    end
endfunction

function automatic logic [31:0] pycore_set_tag_addr(
    input logic [31:0] tbl, input logic [31:0] probe_idx
);
    begin
        // tbl + 16 + probe_idx * 32
        pycore_set_tag_addr = tbl + 32'd16 + (probe_idx << 5);
    end
endfunction

function automatic logic [31:0] pycore_set_table_ptr_addr(
    input logic [31:0] obj_addr
);
    begin
        pycore_set_table_ptr_addr = obj_addr + 32'd16;
    end
endfunction

function automatic logic [31:0] pycore_set_alloc_bytes(
    input logic [31:0] slot_count
);
    begin
        // Contiguous BUILD_SET: 32-byte object + slot_count * 32-byte slots.
        pycore_set_alloc_bytes = 32'd32 + (slot_count << 5);
    end
endfunction

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_set_header(
    input logic [63:0] slot_count,
    input logic [63:0] used
);
    begin
        pycore_set_header = {slot_count, used};
    end
endfunction

// Same sizing policy as dict (next_pow2(max(4, 2*n))).
function automatic logic [31:0] pycore_set_min_slots(
    input logic [6:0] n_elems
);
    begin
        pycore_set_min_slots = pycore_dict_min_slots(n_elems);
    end
endfunction

function automatic logic pycore_set_needs_grow(
    input logic [63:0] used,
    input logic [63:0] slot_count
);
    begin
        pycore_set_needs_grow = pycore_dict_needs_grow(used, slot_count);
    end
endfunction

// -------------------------------------------------------------------------
// Heap allocator address-space parameters.
//
// The object heap lives at the bottom of dmem, below the frame stack which
// starts at FRAME_STACK_BASE (0xC000).  PYCORE_HEAP_BASE is left at 0x0400
// to leave a 1 KB buffer at address 0 for any PTR-based user data.  The
// bump pointer starts at PYCORE_HEAP_BASE and grows upward; a trap is
// raised when it would exceed PYCORE_HEAP_LIMIT.
//
// Default memory map (DMEM_BLOCK_COUNT=16 → 64 KB):
//   0x0000 – 0x03FF  (1 KB)   reserved / user PTR data
//   0x0400 – 0xBFFF  (~47 KB) container heap (this region)
//   0xC000 – 0xFFFF  (16 KB)  call-frame stack
// -------------------------------------------------------------------------
localparam logic [31:0] PYCORE_HEAP_BASE  = 32'h0000_0400;
localparam logic [31:0] PYCORE_HEAP_LIMIT = 32'h0000_C000;

// -------------------------------------------------------------------------
// LIST in-dmem layout v2 — growable split object/buffer (Phase A).
//
// The list HANDLE (PY_TAG_LIST, value={64'd0, obj_addr[63:0]}) names a
// stable, 32-byte LIST OBJECT that never moves; every alias of the handle
// stays valid across growth because growth only ever updates the object's
// ob_item field, never the object's own address:
//
//   obj_addr + 0  : header  { capacity[63:0] , length[63:0] }
//   obj_addr + 16 : { 64'd0 , ob_item[63:0] }   (element buffer byte addr)
//
// The element BUFFER at ob_item is relocatable (capacity * 32 bytes):
//
//   ob_item + idx*32      : element[idx] value[127:0]
//   ob_item + idx*32 + 16 : element[idx] tag   {124'b0, tag[3:0]}
//
// Element stride = 32 bytes (2 slots), same as v1.  Empty list: capacity=0,
// length=0, ob_item=0 — no buffer allocation (object only).
//
// This replaces the v1 inline layout (header immediately followed by
// elements at the same base) that made growth impossible without
// relocating every alias.  pycore_list_val_addr / pycore_list_tag_addr now
// take the BUFFER base (ob_item), not the object address — callers must
// read the object's ob_item field first (see CONT_SUBSCR_LIST /
// CONT_STORE_LIST / CONT_LIST_APPEND in pycore_core.sv).
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

// Byte address of the list object's ob_item (buffer pointer) slot.
function automatic logic [31:0] pycore_list_obitem_addr(
    input logic [31:0] obj_addr
);
    begin
        pycore_list_obitem_addr = obj_addr + 32'd16;
    end
endfunction

// Extract the buffer byte address from a slot read at obj_addr+16.
function automatic logic [63:0] pycore_list_obitem(
    input logic [PYCORE_VAL_WIDTH-1:0] slot
);
    begin
        pycore_list_obitem = slot[63:0];
    end
endfunction

// Byte address of element i's VALUE slot within the BUFFER at buf_addr.
function automatic logic [31:0] pycore_list_val_addr(
    input logic [31:0] buf_addr,
    input logic [31:0] idx
);
    begin
        // buf_addr + idx*32 (no header inside the buffer — see layout above)
        pycore_list_val_addr = buf_addr + (idx << 5);
    end
endfunction

// Byte address of element i's TAG slot within the BUFFER at buf_addr.
function automatic logic [31:0] pycore_list_tag_addr(
    input logic [31:0] buf_addr,
    input logic [31:0] idx
);
    begin
        // buf_addr + idx*32 + 16
        pycore_list_tag_addr = buf_addr + (idx << 5) + 32'd16;
    end
endfunction

// Fixed size of the (stable) list object: header (16B) + ob_item (16B).
function automatic logic [31:0] pycore_list_obj_bytes();
    begin
        pycore_list_obj_bytes = 32'd32;
    end
endfunction

// Bytes to allocate for a buffer holding `capacity` elements.
function automatic logic [31:0] pycore_list_buf_bytes(
    input logic [31:0] capacity
);
    begin
        pycore_list_buf_bytes = capacity << 5;
    end
endfunction

// -------------------------------------------------------------------------
// TUPLE in-dmem layout (all addresses 16-byte aligned, 128-bit dmem slots):
//
// Because size lives inline in the handle value field
//   { size[63:0], addr[63:0] },
// tuples need NO header slot in dmem:
//
//   element[i] value : addr + 32*i          (128-bit slot)
//   element[i] tag   : addr + 32*i + 16     ({124'b0, tag[3:0]})
//   allocation bytes : size * 32
//
// Handle: { PY_TAG_TUPLE, {size[63:0], addr[63:0]} }.
// -------------------------------------------------------------------------
function automatic logic [63:0] pycore_tuple_size(
    input logic [PYCORE_VAL_WIDTH-1:0] value
);
    begin
        pycore_tuple_size = value[127:64];
    end
endfunction

function automatic logic [31:0] pycore_tuple_val_addr(
    input logic [31:0] addr,
    input logic [31:0] idx
);
    begin
        // addr + idx*32
        pycore_tuple_val_addr = addr + (idx << 5);
    end
endfunction

function automatic logic [31:0] pycore_tuple_tag_addr(
    input logic [31:0] addr,
    input logic [31:0] idx
);
    begin
        // addr + idx*32 + 16
        pycore_tuple_tag_addr = addr + (idx << 5) + 32'd16;
    end
endfunction

function automatic logic [31:0] pycore_tuple_alloc_bytes(
    input logic [31:0] size
);
    begin
        pycore_tuple_alloc_bytes = size << 5;
    end
endfunction

// -------------------------------------------------------------------------
// CODE OBJECT in-dmem layout (tuple-element convention, 5 fields = 192 bytes):
//
//   Handle: { PY_TAG_CODE_OBJECT, {64'd0, addr[63:0]} }
//
//   field 0 : entry_slot  (INT)  — imem slot index of first code unit
//   field 1 : co_consts   (TUPLE handle; empty tuple allowed)
//   field 2 : co_names    (TUPLE handle; empty tuple allowed)
//   field 3 : metadata    (INT)  — packed
//               value[15:0]  = argcount
//               value[31:16] = nlocals
//               value[47:32] = stacksize
//   field 4 : co_defaults (TUPLE handle; empty ⇒ exact argc match)
//
// Interim model: a "function object" IS a code-object handle (function ≡ code).
// Defaults live on the code object; closures / kwdefaults are future work.
// -------------------------------------------------------------------------
localparam logic [31:0] PYCORE_CODE_FIELD_ENTRY_SLOT  = 32'd0;
localparam logic [31:0] PYCORE_CODE_FIELD_CO_CONSTS   = 32'd1;
localparam logic [31:0] PYCORE_CODE_FIELD_CO_NAMES    = 32'd2;
localparam logic [31:0] PYCORE_CODE_FIELD_METADATA    = 32'd3;
localparam logic [31:0] PYCORE_CODE_FIELD_CO_DEFAULTS = 32'd4;
localparam logic [31:0] PYCORE_CODE_NFIELDS           = 32'd5;
localparam logic [31:0] PYCORE_CODE_OBJECT_BYTES      = 32'd192;

function automatic logic [31:0] pycore_code_field_val_addr(
    input logic [31:0] addr,
    input logic [31:0] i
);
    begin
        pycore_code_field_val_addr = pycore_tuple_val_addr(addr, i);
    end
endfunction

function automatic logic [15:0] pycore_code_meta_argcount(
    input logic [PYCORE_VAL_WIDTH-1:0] meta
);
    begin
        pycore_code_meta_argcount = meta[15:0];
    end
endfunction

function automatic logic [15:0] pycore_code_meta_nlocals(
    input logic [PYCORE_VAL_WIDTH-1:0] meta
);
    begin
        pycore_code_meta_nlocals = meta[31:16];
    end
endfunction

// -------------------------------------------------------------------------
// General OBJECT layout under PY_TAG_OBJECT (M1):
//
//   Handle: { PY_TAG_OBJECT, {64'd0, obj_addr[63:0]} }
//
//   obj + 0  : ob_head (raw, untagged 128-bit word)
//                [127:96] ob_kind  (PY_OBK_*)
//                [95:64]  ob_flags
//                [63:0]   ob_type  (byte addr of TYPE object; 0 = none)
//   obj + 16 : { 124'b0, PY_TAG_OBJECT }   // self-tag; preserves 32B stride
//   obj + 32 : field0 value      obj + 48 : field0 tag
//   obj + 64 : field1 value      ...
//
// Field *i* lives at pycore_tuple_val_addr(obj, i+1).  pycore_obj_field_*
// helpers are thin aliases so call sites read clearly.
//
// Kind field tables:
//   OBK_INSTANCE     field0=__dict__ (DICT)
//   OBK_TYPE         field0=tp_dict, field1=tp_base, field2=tp_name
//   OBK_BOUND_METHOD field0=__func__, field1=__self__
//   OBK_BUILTIN      field0=builtin_id (INT), field1=bound_self
//   OBK_BYTEARRAY    field0=length, field1=buf_addr, field2=capacity
//   OBK_EXCEPTION    field0=exc_type, field1=args
// -------------------------------------------------------------------------
localparam logic [31:0] PYCORE_OBJ_HDR_BYTES        = 32'd32;
localparam logic [31:0] PYCORE_OBJ_INSTANCE_BYTES   = 32'd64;   // hdr + 1 field
localparam logic [31:0] PYCORE_OBJ_TYPE_BYTES       = 32'd128;  // hdr + 3 fields
localparam logic [31:0] PYCORE_OBJ_BOUND_METHOD_BYTES = 32'd96; // hdr + 2
localparam logic [31:0] PYCORE_OBJ_BUILTIN_BYTES    = 32'd96;
localparam logic [31:0] PYCORE_OBJ_BYTEARRAY_BYTES  = 32'd128;  // hdr + 3
localparam logic [31:0] PYCORE_OBJ_EXCEPTION_BYTES  = 32'd96;

function automatic logic [PYCORE_VAL_WIDTH-1:0] pycore_pack_ob_head(
    input logic [31:0] kind,
    input logic [31:0] flags,
    input logic [63:0] type_addr
);
    begin
        pycore_pack_ob_head = {kind, flags, type_addr};
    end
endfunction

function automatic logic [31:0] pycore_ob_kind(
    input logic [PYCORE_VAL_WIDTH-1:0] head
);
    begin
        pycore_ob_kind = head[127:96];
    end
endfunction

function automatic logic [31:0] pycore_ob_flags(
    input logic [PYCORE_VAL_WIDTH-1:0] head
);
    begin
        pycore_ob_flags = head[95:64];
    end
endfunction

function automatic logic [63:0] pycore_ob_type(
    input logic [PYCORE_VAL_WIDTH-1:0] head
);
    begin
        pycore_ob_type = head[63:0];
    end
endfunction

// Field i value/tag — alias of tuple helpers with the +1 header offset.
function automatic logic [31:0] pycore_obj_field_val_addr(
    input logic [31:0] obj,
    input logic [31:0] i
);
    begin
        pycore_obj_field_val_addr = pycore_tuple_val_addr(obj, i + 32'd1);
    end
endfunction

function automatic logic [31:0] pycore_obj_field_tag_addr(
    input logic [31:0] obj,
    input logic [31:0] i
);
    begin
        pycore_obj_field_tag_addr = pycore_tuple_tag_addr(obj, i + 32'd1);
    end
endfunction

// -------------------------------------------------------------------------
// Boot record — two tagged-entry pairs just below the heap base, inside the
// reserved low region:
//
//   PYCORE_BOOT_RECORD_ADDR + 0  : module code object handle (CODE_OBJECT)
//   PYCORE_BOOT_RECORD_ADDR + 32 : globals dict handle (DICT)
//
// Written by image_from_source.py; read by S_BOOT at reset when BOOT_EN=1.
// -------------------------------------------------------------------------
localparam logic [31:0] PYCORE_BOOT_RECORD_ADDR = 32'h0000_03E0;

`endif
