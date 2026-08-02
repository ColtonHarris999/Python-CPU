# pycore builtins (firmware ROM)

Pure-Python sources for names resolved on the LEGB **B**uildin
lookup. Each module will be compiled to bytecode and placed at a
known address in the pycore boot image (hex fixtures in the current
test flow). Small helpers may later be inlined instead of a PC jump.

**Architecture:** prefer hardware `OBK_BUILTIN` / `BI_*` CALL fast paths
for known tags; keep these `.py` bodies as **miss / protocol**
implementations (see `planning/builtins_bytecode_support_plan.md`).
Example: `BI_LEN` reads container headers; Python `len` should only
handle `obj.__len__()`, not recount with a for-loop.

Status values: **not implemented** (stub only), **blocked** (stub +
documented hard dependency), **in progress** (partial pure-Python with
known gaps), **implemented** (pure-Python source ready for ROM compile
on the supported opcode subset), **in ROM** (compiled into the boot
image).

## Cross-cutting pycore constraints

These limit every firmware builtin:

| Constraint | Impact |
| --- | --- |
| `RAISE_VARARGS` oparg 1 is fatal-only | Can `raise` to halt with `PY_TRAP_RAISE` (17); no handlers / `TypeError` objects yet. Prefer `raise` over `% 0` where touched. |
| **`CALL_KW` / `CALL_FUNCTION_EX` unfrozen** | Hardware binder supports keyword / `*args` / `**kwargs` calls on `CODE_OBJECT` (see `planning/call_kw_support_plan.md`). ROM modules may use `sep=` / `key=` / `*args` when implemented as Python `CODE_OBJECT`s. Native `OBK_BUILTIN` / `BI_*` paths remain positional-only (`CALL_FILTER` on kwargs). |
| No `YIELD_VALUE` | `enumerate`/`zip`/`map`/`filter`/`reversed` return lists, not iterators |
| `TO_BOOL` widened | `None` + LIST/TUPLE/DICT/SET/inline RANGE truthiness work; `OBJECT` `__bool__`/`__len__` protocol still TYPE-traps |
| `COMPARE_OP` numeric only | `min`/`max`/`sorted` TYPE-trap on str/containers |
| No negative indices | `reversed` counts length explicitly |
| Comprehensions emit `RERAISE` | Policy C: prefer `out += [x]` / `{*iterable}` (see `bytecode_support.md`) |
| List/set growth | `LIST_EXTEND` / `SET_UPDATE` need excore for non-empty work |
| `UNPACK_EX` + `CALL_INTRINSIC_1` (LIST_TO_TUPLE) | Starred unpack and `(*lst,)` / list→tuple materialization are available |
| Nested plan docs | Deep blockers: `compile.md`, `eval.md`, `exec.md`, `open.md`, `super.md`, `property.md`, `ord.md`, `chr.md` |
| Bytecode follow-up plan | `planning/builtins_next_steps_plan.md` — what the builtins agent should do next |

## Builtin functions

| Builtin | Description | Status | Notes |
| --- | --- | --- | --- |
| `abs` | Return the absolute value of a number. | implemented | INT/BOOL/FLOAT via `<` + `UNARY_NEGATIVE`. |
| `aiter` | Return an asynchronous iterator for an asynchronous iterable. | blocked | Async/await deferred (`GET_AWAITABLE`/`SEND`). |
| `all` | Return True if all elements of the iterable are true (or if empty). | implemented | TO_BOOL limits apply. |
| `anext` | Return the next item from an asynchronous iterator. | blocked | Async/await deferred. |
| `any` | Return True if any element of the iterable is true. | implemented | TO_BOOL limits apply. |
| `ascii` | Return an ASCII-only repr, escaping non-ASCII characters. | blocked | Needs `repr` for str + `ord` for non-ASCII escapes. |
| `bin` | Convert an integer to a binary string prefixed with '0b'. | implemented | String concat digit loop. |
| `bool` | Return a Boolean value; subclass of int used as the Boolean type. | implemented | Truthiness only — does not fabricate a `bool` type object. |
| `breakpoint` | Drop into the debugger at the call site (PEP 553). | blocked | No `sys.breakpointhook` / debugger. |
| `bytearray` | Return a new mutable bytearray object. | blocked | Seeded as `BI_BYTEARRAY`; CALL → excore. Cannot alloc in pure Python. |
| `bytes` | Return a new immutable bytes object. | blocked | `PY_TAG_BYTES` exists; no runtime constructor API. |
| `callable` | Return True if the object appears callable. | in progress | Heuristic via `__call__` in `__dict__`; no tag probe for `CODE_OBJECT`. |
| `chr` | Return the Unicode character for an integer code point. | blocked | See `chr.md` — need `BI_CHR` / string-from-bytes. |
| `classmethod` | Transform a method into a class method. | blocked | No classmethod kind; image folding rejects `@classmethod`. |
| `compile` | Compile source into a code object usable by exec/eval. | blocked | See `compile.md`. |
| `complex` | Create a complex number from real/imag or a string. | blocked | COMPLEX ALU tag exists; no runtime constructor. |
| `delattr` | Delete a named attribute from an object. | implemented | Interim: `del obj.__dict__[name]` (no MRO). |
| `dict` | Create a new dictionary. | implemented | From iterable of pairs via `UNPACK_SEQUENCE` + `STORE_SUBSCR`. No kwargs. |
| `dir` | Return a list of valid attribute names for an object or the local scope. | in progress | Instance `__dict__` keys only; no-arg / MRO names blocked. |
| `divmod` | Return the pair (quotient, remainder) of integer division. | implemented | `(a // b, a % b)`. |
| `enumerate` | Return an enumerate object yielding (index, item) pairs. | implemented | Returns a **list** of pairs (no YIELD). |
| `eval` | Evaluate a Python expression from a string or code object. | blocked | See `eval.md`. |
| `exec` | Execute Python statements from a string or code object. | blocked | See `exec.md`. |
| `filter` | Construct an iterator of items for which a function returns true. | implemented | Returns a **list**; `function is None` uses TO_BOOL. |
| `float` | Convert a string or number to floating point. | in progress | `x * 1.0` for numerics; `_parse_float_string` helper; no auto str dispatch. |
| `format` | Convert a value to a formatted representation ("format_spec"). | in progress | Empty spec → INT/BOOL/None stringify; non-empty specs blocked (`FORMAT_WITH_SPEC`). |
| `frozenset` | Return a new frozenset object. | blocked | `PY_TAG_FROZENSET` reserved / unimplemented. |
| `getattr` | Return the named attribute of an object, with optional default. | implemented | Interim: `obj.__dict__` only (CONTAINS_OP + subscript). No MRO. |
| `globals` | Return the current global symbol table as a dict. | blocked | Frame globals pointer not exposed to Python. |
| `hasattr` | Return True if the object has the named attribute. | implemented | Interim: `name in obj.__dict__` only. |
| `hash` | Return the hash value of an object. | blocked | Hash is internal to dict/set probes; not callable from Python. |
| `help` | Invoke the built-in help system. | blocked | No docstring store / interactive I/O. |
| `hex` | Convert an integer to a lowercase hexadecimal string prefixed with '0x'. | implemented | String concat digit loop. |
| `id` | Return the identity (unique integer) of an object. | blocked | No address-expose primitive. |
| `input` | Read a line from stdin (after an optional prompt) and return it. | blocked | No stdin device. |
| `int` | Convert a number or string to an integer. | in progress | Numeric truncate + `_parse_int_string` when `base` given; `int("5")` without base still needs tag dispatch. |
| `isinstance` | Return True if the object is an instance of a type or tuple of types. | implemented | Single-class `classinfo` via `__class__`/`__base__` walk. Tuple-of-types form blocked. |
| `issubclass` | Return True if a class is a subclass of a class or tuple of classes. | implemented | Single-class `classinfo` via `__base__` walk (depth ≤ 8). |
| `iter` | Return an iterator for an object (or call a sentinel-producing callable). | in progress | One-arg materializes a list; sentinel form blocked (`% 0`). |
| `len` | Return the number of items in a container. | implemented | Miss path: `obj.__len__()`. Native `BI_LEN` owns container header reads. |
| `list` | Create a new list, optionally from an iterable. | implemented | `out += [x]` per element (excore LIST_EXTEND). |
| `locals` | Return the current local symbol table as a dict. | blocked | No frame-local namespace objects. |
| `map` | Return an iterator that applies a function to every item of iterables. | implemented | Single iterable → **list**. Multi-iter `*args` blocked. |
| `max` | Return the largest item in an iterable or among arguments. | implemented | `(iterable)` or `(a, b)` only. Empty → `None`. Native `BI_MAX` still on-core for 2-arg. |
| `memoryview` | Return a memory view object over a bytes-like object. | blocked | No buffer protocol / memoryview kind. |
| `min` | Return the smallest item in an iterable or among arguments. | implemented | Same signature limits as `max`. |
| `next` | Retrieve the next item from an iterator. | in progress | List-queue pop of `[0]`; no real iterator protocol. |
| `object` | Return a new featureless object; base for all classes. | blocked | No `OBK_INSTANCE` alloc without a class body. |
| `oct` | Convert an integer to an octal string prefixed with '0o'. | implemented | String concat digit loop. |
| `open` | Open a file and return a corresponding file object. | blocked | See `open.md`. |
| `ord` | Return the Unicode code point for a one-character string. | blocked | See `ord.md`. |
| `pow` | Return base**exp, optionally modulo mod. | implemented | Binary modexp for non-neg exp; neg exp+mod → trap. |
| `print` | Print objects to a stream (default stdout), separated by sep and ended by end. | blocked | `BI_PRINT` → excore I/O; kwargs/`*args` OK on a ROM `CODE_OBJECT` wrapper once seeded. |
| `property` | Return a property attribute with optional getter/setter/deleter. | blocked | See `property.md`. |
| `range` | Return an immutable sequence of numbers (start, stop, step). | implemented | Interim **list** materialization. Native `BI_RANGE` (`PY_TAG_RANGE`) preferred. |
| `repr` | Return a string containing a printable representation of an object. | in progress | INT/BOOL/None only; containers/str quoting blocked. |
| `reversed` | Return a reverse iterator over a sequence. | implemented | Returns a **list**. |
| `round` | Round a number to a given precision in decimal digits. | implemented | Half-away-from-zero (not banker's rounding). |
| `set` | Create a new set, optionally from an iterable. | implemented | `{*()}` / `{*iterable}` → SET_UPDATE (excore). Native `BI_SET` still on-core. |
| `setattr` | Set a named attribute on an object. | implemented | Interim: `obj.__dict__[name] = value`. |
| `slice` | Return a slice object representing indices for extended slicing. | blocked | `BINARY_SLICE`/`STORE_SLICE` deferred; no slice object kind. |
| `sorted` | Return a new sorted list from an iterable. | implemented | Bubble sort; numeric COMPARE_OP only; no key=/reverse=. |
| `staticmethod` | Transform a method into a static method. | blocked | Image-time `BI_STATICMETHOD` (id 0) unwrap; runtime wrapper blocked. |
| `str` | Create a new string object from an object or buffer. | in progress | BOOL/None/INT decimal; STR identity needs tag probe. |
| `sum` | Return the sum of a start value and an iterable of numbers. | implemented | `start` default 0. |
| `super` | Return a proxy object that delegates method calls to a parent or sibling class. | blocked | See `super.md`. |
| `tuple` | Create a new tuple, optionally from an iterable. | in progress | `tuple()` → `()`. Non-empty iterable needs `UNPACK_EX` / dynamic BUILD_TUPLE — traps. |
| `type` | Return the type of an object, or create a new type object. | in progress | One-arg: `obj.__class__`. Three-arg needs `LOAD_BUILD_CLASS`. |
| `vars` | Return the __dict__ of an object, or locals() with no argument. | in progress | `obj.__dict__`; no-arg → `{}` (not real locals). |
| `zip` | Iterate over several iterables in parallel, yielding tuples. | implemented | Two iterables → **list** of pairs. |

## pycore-specific helpers

| Builtin | Description | Status | Notes |
| --- | --- | --- | --- |
| `from_bytes` | int.from_bytes-style constructor helper (pycore BI_FROM_BYTES). | blocked | Excore `PY_TRAP_BUILTIN_CALL`; no BYTES payload reader in Python. |
| `to_bytes` | int.to_bytes-style conversion helper (pycore BI_TO_BYTES). | blocked | Excore path; needs BYTES allocation. |
| `list_append` | list.append method helper (pycore BI_LIST_APPEND). | implemented | `lst += [value]` mirror; prefer LIST_APPEND opcode / excore grow. |

## Source layout

```text
pycore_firmware/builtins/<name>.py      # one module per builtin
pycore_firmware/builtins/<name>.md      # deep plans for blocked builtins
pycore_firmware/builtins/builtins.md    # this inventory
```

| Kind | Count |
| --- | --- |
| Python modules | 73 |
| Plan docs | 8 (`compile`, `eval`, `exec`, `open`, `super`, `property`, `ord`, `chr`) |
| Status: implemented | 31 |
| Status: in progress | 12 |
| Status: blocked | 30 |

### Implemented (ROM-ready happy path)

`abs`, `all`, `any`, `bin`, `bool`, `delattr`, `dict`, `divmod`,
`enumerate`, `filter`, `getattr`, `hasattr`, `hex`, `isinstance`,
`issubclass`, `len`, `list`, `list_append`, `map`, `max`, `min`, `oct`,
`pow`, `range`, `reversed`, `round`, `set`, `setattr`, `sorted`, `sum`,
`zip`

### In progress (usable subset)

`callable`, `dir`, `float`, `format`, `int`, `iter`, `next`, `repr`,
`str`, `tuple`, `type`, `vars`

### Blocked (stub + notes/plans)

`aiter`, `anext`, `ascii`, `breakpoint`, `bytearray`, `bytes`, `chr`,
`classmethod`, `compile`, `complex`, `eval`, `exec`, `frozenset`,
`globals`, `hash`, `help`, `id`, `input`, `locals`, `memoryview`,
`object`, `open`, `ord`, `print`, `property`, `slice`, `staticmethod`,
`super`, `from_bytes`, `to_bytes`
