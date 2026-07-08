# PyCore Bytecode Support Lists (CPython 3.14)

This file lists **all 154** CPython 3.14 opcodes and classifies each for
the current PyCore implementation. Hardware-fit categories come from
`pycore/targets/pycore.json` (the same taxonomy used by
`pycore/tools/analyze_bytecode.py`).

## Hardware-fit categories (`hw_class`)

| hw_class | fit | Meaning |
| --- | --- | --- |
| `REG` | native | register-file index read/write; no compute |
| `IMM` | native | value materialized from oparg at decode |
| `CONST` | costly | ROM read; loop-hoistable |
| `ALU1` | native | single-cycle integer/bitwise leaf |
| `ALUN` | costly | multi-cycle bounded numeric (mul/div/rem/pow/fpu) |
| `PRED` | native | comparison/truthiness producing a bool |
| `BRANCH` | native | static-target control transfer / markers |
| `FRAME` | heavy | call/return needs frame alloc + spill (intrinsically heavy on any target) |
| `OBJECT` | infeasible | needs runtime objects/dicts/iterators; cannot map to a scalar tagged-value datapath |
| `INTERNAL` | n/a | interpreter plumbing (INSTRUMENTED_*, CACHE, RESERVED, EXTENDED_ARG, ENTER_EXECUTOR, INTERPRETER_EXIT, JUMP/JUMP_NO_INTERRUPT pseudo, ANNOTATIONS_PLACEHOLDER); never reaches a hardware target -> strip, not a gap |

For unsupported bytecodes, behavior is strict:

1. preprocess rejects the program before artifact generation when possible (`reject`);
2. if one still reaches decode, it is treated as illegal and traps (`trap`).

In short, unsupported bytecodes do not have in-hardware fallback emulation today.
Object-protocol opcodes (`hw_class=OBJECT`) are intended for a RISC-V trap handler.

## Fully supported bytecodes (17)

Executed correctly on the current PyCore scalar fast path.

| Bytecode | Description | hw_class | PyCore-specific note |
| --- | --- | --- | --- |
| `BINARY_OP` | Implements binary and in-place operators selected by oparg.<br><br>`rhs = STACK.pop()`<br>`lhs = STACK.pop()`<br>`STACK.append(lhs op rhs)` | `ALU1 (native)` | Fully supported on the current scalar stack (INT, BOOL, FLOAT, SHORT_STR, LONG_STR); generic OBJECT values cannot reach the stack today. preprocess rejects opargs 4/17/26 (@ and subscript read). hw_class varies by oparg: ALU1 for cheap ops, ALUN for mul/div/rem/pow. Strings: only oparg 0/13 (`+`, `+=`) concatenates SHORT_STR/LONG_STR pairs in hardware (result ≤15 bytes → SHORT_STR, else LONG_STR); other BINARY_OP opargs on strings trap. |
| `JUMP_BACKWARD` | Decrements bytecode counter by delta. Checks for interrupts. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `JUMP_FORWARD` | Increments bytecode counter by delta. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `LOAD_CONST` | Pushes co_consts[consti] onto the stack. | `CONST (costly)` | Executed on the PyCore scalar fast path. |
| `LOAD_FAST` | Pushes a reference to the local co_varnames[var_num] onto the stack. | `REG (native)` | Executed on the PyCore scalar fast path. |
| `LOAD_FAST_BORROW` | Pushes a borrowed reference to the local co_varnames[var_num] onto the stack. | `REG (native)` | Treated as `LOAD_FAST`. |
| `LOAD_FAST_CHECK` | Loads a fast local, raising UnboundLocalError if uninitialized. | `REG (native)` | == LOAD_FAST under PyCore UNINITIALIZED-trap policy. |
| `LOAD_SMALL_INT` | Pushes a small immediate integer encoded in oparg. | `IMM (native)` | Executed on the PyCore scalar fast path. |
| `POP_ITER` | Removes the iterator from the top of the stack. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `POP_JUMP_IF_FALSE` | If STACK[-1] is false, increments the bytecode counter by delta. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `POP_JUMP_IF_TRUE` | If STACK[-1] is true, increments the bytecode counter by delta. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `POP_TOP` | Removes the top-of-stack item. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `RETURN_VALUE` | Returns with STACK[-1] to the caller of the function. | `BRANCH (native)` | Executed on the PyCore scalar fast path. |
| `STORE_FAST` | Stores STACK.pop() into the local co_varnames[var_num]. | `REG (native)` | Executed on the PyCore scalar fast path. |
| `UNARY_INVERT` | Implements STACK[-1] = ~STACK[-1]. | `ALU1 (native)` | Executed on the PyCore scalar fast path. |
| `UNARY_NEGATIVE` | Implements STACK[-1] = -STACK[-1]. | `ALU1 (native)` | Executed on the PyCore scalar fast path. |
| `UNARY_NOT` | Implements STACK[-1] = not STACK[-1]. | `PRED (native)` | Executed on the PyCore scalar fast path. |

## Partially supported bytecodes (4)

Recognized but incomplete or limited on the current PyCore datapath.

| Bytecode | Description | hw_class | PyCore-specific note |
| --- | --- | --- | --- |
| `CALL` | Calls a callable object with the number of arguments specified by argc. | `FRAME (heavy)` | Decoded but incomplete on the current PyCore datapath. |
| `COMPARE_OP` | Performs a Boolean operation. The operation name can be found in cmp_op[opname >> 5]. If the fifth-lowest bit of opname is set (opname & 16), the result should be coerced to bool. | `PRED (native)` | Decoded but incomplete on the current PyCore datapath. |
| `COPY` | Duplicates the i-th stack item to the top without removing it. | `REG (native)` | add COPY to decode (stack-pointer-relative read). |
| `SWAP` | Swaps the top of the stack with the i-th element below it. | `REG (native)` | Decoded but incomplete on the current PyCore datapath. |

## Stripped bytecodes (interpreter plumbing) (32)

Removed or absorbed by preprocess/fetch; never executed architecturally.

| Bytecode | Description | hw_class | PyCore-specific note |
| --- | --- | --- | --- |
| `ANNOTATIONS_PLACEHOLDER` | Placeholder opcode for annotation metadata; not executed. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `CACHE` | Rather than being an actual instruction, this opcode is used to mark extra space for the interpreter to cache useful data directly in the bytecode itself. It is automatically hidden by all dis utilities, but can be viewed with show_caches=True. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `ENTER_EXECUTOR` | Enters a tier-2 executor; interpreter internal. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `EXTENDED_ARG` | Prefixes any opcode which has an argument too big to fit into the default one byte. ext holds an additional byte which act as higher bits in the argument. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_CALL` | Instrumented variant of CALL. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_CALL_FUNCTION_EX` | Instrumented variant of CALL_FUNCTION_EX. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_CALL_KW` | Instrumented variant of CALL_KW. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_END_ASYNC_FOR` | Instrumented variant of END_ASYNC_FOR. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_END_FOR` | Instrumented variant of END_FOR. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_END_SEND` | Instrumented variant of END_SEND. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_FOR_ITER` | Instrumented variant of FOR_ITER. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_INSTRUCTION` | Per-instruction tracing hook. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_JUMP_BACKWARD` | Instrumented variant of JUMP_BACKWARD. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_JUMP_FORWARD` | Instrumented variant of JUMP_FORWARD. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_LINE` | Line-tracing instrumentation hook. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_LOAD_SUPER_ATTR` | Instrumented variant of LOAD_SUPER_ATTR. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_NOT_TAKEN` | Instrumented variant of NOT_TAKEN. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_POP_ITER` | Instrumented variant of POP_ITER. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_POP_JUMP_IF_FALSE` | Instrumented variant of POP_JUMP_IF_FALSE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_POP_JUMP_IF_NONE` | Instrumented variant of POP_JUMP_IF_NONE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_POP_JUMP_IF_NOT_NONE` | Instrumented variant of POP_JUMP_IF_NOT_NONE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_POP_JUMP_IF_TRUE` | Instrumented variant of POP_JUMP_IF_TRUE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_RESUME` | Instrumented variant of RESUME. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_RETURN_VALUE` | Instrumented variant of RETURN_VALUE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INSTRUMENTED_YIELD_VALUE` | Instrumented variant of YIELD_VALUE. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `INTERPRETER_EXIT` | Exits the interpreter with a return value; internal. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `JUMP` | Undirected relative jump pseudo-instruction; replaced by forward/backward jumps in the assembler. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `JUMP_NO_INTERRUPT` | Undirected relative jump pseudo-instruction that does not allow interrupts. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `NOP` | Do nothing code. Used as a placeholder by the bytecode optimizer, and to generate line tracing events. | `BRANCH (native)` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `NOT_TAKEN` | Do nothing code. | `BRANCH (native)` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `RESERVED` | Reserved opcode slot; not used. | `INTERNAL` | Stripped or folded by preprocess/fetch; never executed in hardware. |
| `RESUME` | A no-op. Performs internal tracing, debugging and optimization checks. | `BRANCH (native)` | Stripped or folded by preprocess/fetch; never executed in hardware. |

## Fully unsupported bytecodes (preprocess reject) (13)

Rejected by preprocess before artifact generation.

| Bytecode | Description | hw_class | PyCore-specific note |
| --- | --- | --- | --- |
| `DELETE_FAST` | Deletes (clears) a fast local variable slot. | `REG (native)` | RF-domain local delete (mark UNINITIALIZED); cheap to add. |
| `JUMP_BACKWARD_NO_INTERRUPT` | Decrements bytecode counter by delta without checking for interrupts. | `BRANCH (native)` | Rejected by preprocess before artifact generation. |
| `JUMP_IF_FALSE` | Conditional jump if TOS is falsy without popping the stack (pseudo-instruction). | `BRANCH (native)` | 3.14 peek-branch (net 0, does not pop); replaces 3.13 JUMP_IF_FALSE_OR_POP. |
| `JUMP_IF_TRUE` | Conditional jump if TOS is truthy without popping the stack (pseudo-instruction). | `BRANCH (native)` | 3.14 peek-branch (net 0, does not pop). |
| `LOAD_FAST_AND_CLEAR` | Loads a fast local and clears the slot to NULL (compiler temp semantics). | `REG (native)` | Rejected by preprocess before artifact generation. |
| `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | Pushes two borrowed fast locals (compiler-fused dual load). | `REG (native)` | compiler-fused dual load not executed. fused dual-local read, or split in preprocess. |
| `LOAD_FAST_LOAD_FAST` | Pushes two fast locals (compiler-fused dual load). | `REG (native)` | Rejected by preprocess before artifact generation. |
| `POP_JUMP_IF_NONE` | If TOS is None, increments the bytecode counter by delta. | `BRANCH (native)` | None identity test; no None scalar in PyCore. |
| `POP_JUMP_IF_NOT_NONE` | If TOS is not None, increments the bytecode counter by delta. | `BRANCH (native)` | None identity test; no None scalar in PyCore. |
| `STORE_FAST_LOAD_FAST` | Stores one fast local and loads another (fused store/load). | `REG (native)` | executes fine (two RF accesses) but is a fold boundary. |
| `STORE_FAST_MAYBE_NULL` | Stores a fast local that may be NULL. | `REG (native)` | Rejected by preprocess before artifact generation. |
| `STORE_FAST_STORE_FAST` | Stores two fast locals (compiler-fused dual store). | `REG (native)` | compiler-fused dual store not executed. |
| `TO_BOOL` | Implements STACK[-1] = bool(STACK[-1]). | `PRED (native)` | truthiness coercion before branch not executed. add TO_BOOL (scalar truthiness already in branch unit). |

## Fully unsupported bytecodes (runtime trap) (88)

Not implemented in hardware; traps if reached (intended for RISC-V trap handler).

| Bytecode | Description | hw_class | PyCore-specific note |
| --- | --- | --- | --- |
| `BINARY_SLICE` | Implements container[start:end] (binary slice load). | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `BUILD_INTERPOLATION` | Constructs a new string.templatelib.Interpolation instance from a value and its source expression and pushes the resulting object onto the stack. | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `BUILD_LIST` | Works as BUILD_TUPLE, but creates a list. | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `BUILD_MAP` | Pushes a new dictionary object onto the stack. Pops 2 * count items so that the dictionary holds count entries: {..., STACK[-4]: STACK[-3], STACK[-2]: STACK[-1]}. | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `BUILD_SET` | Works as BUILD_TUPLE, but creates a set. | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `BUILD_SLICE` | Pushes a slice object on the stack (argc 2 or 3). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `BUILD_STRING` | Concatenates count strings from the stack and pushes the resulting string onto the stack. | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `BUILD_TEMPLATE` | Constructs a new string.templatelib.Template instance from a tuple of strings and a tuple of interpolations and pushes the resulting object onto the stack | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `BUILD_TUPLE` | Creates a tuple consuming count items from the stack, and pushes the resulting tuple onto the stack | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `CALL_FUNCTION_EX` | Calls a callable object with variable set of positional and keyword arguments. If the lowest bit of flags is set, the top of the stack contains a mapping object containing additional keyword arguments. | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `CALL_INTRINSIC_1` | Calls an intrinsic function with one argument. Passes STACK[-1] as the argument and sets STACK[-1] to the result. Used to implement functionality that is not performance critical. | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `CALL_INTRINSIC_2` | Calls an intrinsic function with two arguments. Used to implement functionality that is not performance critical | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `CALL_KW` | Calls a callable with positional and named keyword arguments. | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `CHECK_EG_MATCH` | Performs exception matching for except*. Applies split(STACK[-1]) on the exception group representing STACK[-2]. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `CHECK_EXC_MATCH` | Performs exception matching for except. Tests whether the STACK[-2] is an exception matching STACK[-1]. Pops STACK[-1] and pushes the boolean result of the test. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `CLEANUP_THROW` | Handles an exception raised during a generator.throw or generator.close call through the current frame. If STACK[-1] is an instance of StopIteration, pop three values from the stack and push its value member. Otherwise, re-raise STACK[-1]. | `OBJECT` | Object subsystem OBJ_GEN (distance 5; needs suspendable/resumable frames). |
| `CONTAINS_OP` | Performs in comparison, or not in if invert is 1. | `OBJECT` | Object subsystem OBJ_DYN (distance 1; needs reference identity / container membership). |
| `CONVERT_VALUE` | Convert value to a string, depending on oparg | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `COPY_FREE_VARS` | Copies the n free (closure) variables from the closure into the frame. Removes the need for special code on the caller's side when calling closures. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `DELETE_ATTR` | Implements: obj = STACK.pop() del obj.name. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `DELETE_DEREF` | Empties the cell contained in slot i of the "fast locals" storage. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `DELETE_GLOBAL` | Works as DELETE_NAME, but deletes a global name. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `DELETE_NAME` | Implements del name, where namei is the index into codeobject.co_names attribute of the :ref:`code object `. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `DELETE_SUBSCR` | Implements del container[key]. | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `DICT_MERGE` | Like DICT_UPDATE but raises an exception for duplicate keys. | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `DICT_UPDATE` | Implements: map = STACK.pop() dict.update(STACK[-i], map). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `END_ASYNC_FOR` | Terminates an :keyword:`async for` loop. Handles an exception raised when awaiting a next item. The stack contains the async iterable in STACK[-2] and the raised exception in STACK[-1]. Both are popped. | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `END_FOR` | Removes the top-of-stack item. | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `END_SEND` | Implements del STACK[-2]. | `OBJECT` | Object subsystem OBJ_GEN (distance 5; needs suspendable/resumable frames). |
| `EXIT_INIT_CHECK` | Verifies __init__() returned None after object construction. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `FORMAT_SIMPLE` | Formats the value on top of stack | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `FORMAT_WITH_SPEC` | Formats the given value with the given format spec | `OBJECT` | Object subsystem OBJ_STR (distance 2; needs string buffer + format runtime). |
| `FOR_ITER` | STACK[-1] is an iterator. Call its iterator.__next__ method. | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `GET_AITER` | Implements STACK[-1] = STACK[-1].__aiter__(). | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `GET_ANEXT` | Implement STACK.append(get_awaitable(STACK[-1].__anext__())) to the stack. | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `GET_AWAITABLE` | Implements STACK[-1] = get_awaitable(STACK[-1]), where get_awaitable(o) returns o if o is a coroutine object or a generator object with the inspect.CO_ITERABLE_COROUTINE flag, or resolves o.__await__. | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `GET_ITER` | Implements STACK[-1] = iter(STACK[-1]). | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `GET_LEN` | Perform STACK.append(len(STACK[-1])). Used in :keyword:`match` statements where comparison with structure of pattern is needed. | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `GET_YIELD_FROM_ITER` | If STACK[-1] is a generator iterator or coroutine object it is left as is. Otherwise, implements STACK[-1] = iter(STACK[-1]). | `OBJECT` | Object subsystem OBJ_ITER (distance 4; needs iterator-protocol dispatch (tp_iter/tp_next)). |
| `IMPORT_FROM` | Loads the attribute co_names[namei] from the module found in STACK[-1]. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `IMPORT_NAME` | Imports the module co_names[namei]. STACK[-1] and STACK[-2] are popped and provide the fromlist and level arguments of __import__. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `IS_OP` | Performs is comparison, or is not if invert is 1. | `OBJECT` | Object subsystem OBJ_DYN (distance 1; needs reference identity / container membership). |
| `LIST_APPEND` | Implements: item = STACK.pop() list.append(STACK[-i], item). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `LIST_EXTEND` | Implements: seq = STACK.pop() list.extend(STACK[-i], seq). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `LOAD_ATTR` | If the low bit of namei is not set, this replaces STACK[-1] with getattr(STACK[-1], co_names[namei>>1]). | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_BUILD_CLASS` | Pushes !builtins.__build_class__ onto the stack. It is later called to construct a class. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_CLOSURE` | Pushes a cell reference from fast locals; replaced with LOAD_FAST in the assembler. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `LOAD_COMMON_CONSTANT` | Pushes a common constant onto the stack. The interpreter contains a hardcoded list of constants supported by this instruction. Used by the :keyword:`assert` statement to load AssertionError. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_DEREF` | Loads the cell contained in slot i of the "fast locals" storage. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `LOAD_FROM_DICT_OR_DEREF` | Pops a mapping off the stack and looks up the name associated with slot i of the "fast locals" storage in this mapping. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `LOAD_FROM_DICT_OR_GLOBALS` | Pops a mapping off the stack and looks up the value for co_names[namei]. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_GLOBAL` | Loads the global named co_names[namei>>1] onto the stack. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_LOCALS` | Pushes a reference to the locals dictionary onto the stack. This is used to prepare namespace dictionaries for LOAD_FROM_DICT_OR_DEREF and LOAD_FROM_DICT_OR_GLOBALS. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_NAME` | Pushes the value associated with co_names[namei] onto the stack. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_SPECIAL` | Performs special method lookup on STACK[-1]. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `LOAD_SUPER_ATTR` | This opcode implements super, both in its zero-argument and two-argument forms (e.g. super().method(), super().attr and super(cls, self).method(), super(cls, self).attr). | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `MAKE_CELL` | Creates a new cell in slot i. If that slot is nonempty then that value is stored into the new cell. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `MAKE_FUNCTION` | Pushes a new function object on the stack built from the code object at STACK[-1]. | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `MAP_ADD` | Implements: value = STACK.pop() key = STACK.pop() dict.__setitem__(STACK[-i], key, value). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `MATCH_CLASS` | STACK[-1] is a tuple of keyword attribute names, STACK[-2] is the class being matched against, and STACK[-3] is the match subject. count is the number of positional sub-patterns. | `OBJECT` | Object subsystem OBJ_MATCH (distance 4; needs type introspection + container probing). |
| `MATCH_KEYS` | STACK[-1] is a tuple of mapping keys, and STACK[-2] is the match subject. | `OBJECT` | Object subsystem OBJ_MATCH (distance 4; needs type introspection + container probing). |
| `MATCH_MAPPING` | If STACK[-1] is an instance of collections.abc.Mapping (or, more technically: if it has the :c:macro:`Py_TPFLAGS_MAPPING` flag set in its :c:member:`~PyTypeObject.tp_flags`), push True onto the stack. Otherwise, push False. | `OBJECT` | Object subsystem OBJ_MATCH (distance 4; needs type introspection + container probing). |
| `MATCH_SEQUENCE` | If STACK[-1] is an instance of collections.abc.Sequence and is not an instance of str/bytes/bytearray (or, more technically: if it has the :c:macro:`Py_TPFLAGS_SEQUENCE` flag set in its :c:member:`~PyTypeObject.tp_flags`), push True onto the stack. Otherwise, push False. | `OBJECT` | Object subsystem OBJ_MATCH (distance 4; needs type introspection + container probing). |
| `POP_BLOCK` | Pops a block from the block stack; exception/frame plumbing. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `POP_EXCEPT` | Pops a value from the stack, which is used to restore the exception state. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `PUSH_EXC_INFO` | Pops a value from the stack. Pushes the current exception to the top of the stack. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `PUSH_NULL` | Pushes a NULL to the stack. | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `RAISE_VARARGS` | Raises an exception (0, 1, or 2 stack arguments depending on oparg). | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `RERAISE` | Re-raises the exception currently on top of the stack. If oparg is non-zero, pops an additional value from the stack which is used to set frame.f_lasti of the current frame. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `RETURN_GENERATOR` | Create a generator, coroutine, or async generator from the current frame. | `OBJECT` | Object subsystem OBJ_GEN (distance 5; needs suspendable/resumable frames). |
| `SEND` | Equivalent to STACK[-1] = STACK[-2].send(STACK[-1]). Used in yield from and await statements. | `OBJECT` | Object subsystem OBJ_GEN (distance 5; needs suspendable/resumable frames). |
| `SETUP_ANNOTATIONS` | Checks whether __annotations__ is defined in locals(), if not it is set up to an empty dict. This opcode is only emitted if a class or module body contains variable annotations statically. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `SETUP_CLEANUP` | Sets up a cleanup block for with/try-finally style unwinding. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `SETUP_FINALLY` | Sets up a finally block on the block stack. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `SETUP_WITH` | Sets up a with-block context manager exit handler. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `SET_ADD` | Implements: item = STACK.pop() set.add(STACK[-i], item). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `SET_FUNCTION_ATTRIBUTE` | Sets a function attribute from a flag-encoded oparg (name, defaults, annotations, etc.). | `OBJECT` | Object subsystem OBJ_CALL (distance 5; needs full call/object-construction protocol (variadic + func-object creation; plain CALL is FRAME, in-scope)). |
| `SET_UPDATE` | Implements: seq = STACK.pop() set.update(STACK[-i], seq). | `OBJECT` | Object subsystem OBJ_BUILD (distance 2; needs heap allocator + container reprs). |
| `STORE_ATTR` | Implements: obj = STACK.pop() value = STACK.pop() obj.name = value. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `STORE_DEREF` | Stores STACK.pop() into the cell contained in slot i of the "fast locals" storage. | `OBJECT` | Object subsystem OBJ_CLOSURE (distance 2; needs heap cell boxes for free vars). |
| `STORE_GLOBAL` | Works as STORE_NAME, but stores the name as a global. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `STORE_NAME` | Implements name = STACK.pop(). namei is the index of name in the attribute codeobject.co_names of the :ref:`code object `. | `OBJECT` | Object subsystem OBJ_NS (distance 3; needs dict + hashing (+ descriptor/MRO for attrs)). |
| `STORE_SLICE` | Implements container[start:end] = value (slice store). | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `STORE_SUBSCR` | Implements container[key] = value. | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `UNPACK_EX` | Implements assignment with a starred target: Unpacks an iterable in STACK[-1] into individual values, where the total number of values can be smaller than the number of items in the iterable: one of the new values will be a list of all leftover items. | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `UNPACK_SEQUENCE` | Unpacks STACK[-1] into count individual values, which are put onto the stack right-to-left. Require there to be exactly count values. | `OBJECT` | Object subsystem OBJ_SEQ (distance 1; needs typed array/memory unit + bounds check). |
| `WITH_EXCEPT_START` | Calls the function in position 4 on the stack with arguments (type, val, tb) representing the exception at the top of the stack. | `OBJECT` | Object subsystem OBJ_EXC (distance 5; needs exception state + stack unwinder). |
| `YIELD_VALUE` | Yields STACK.pop() from a generator. | `OBJECT` | Object subsystem OBJ_GEN (distance 5; needs suspendable/resumable frames). |
