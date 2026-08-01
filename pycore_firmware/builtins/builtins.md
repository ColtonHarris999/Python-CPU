# pycore builtins (firmware ROM)

Pure-Python sources for names resolved on the LEGB **B**uildin
lookup. Each module will be compiled to bytecode and placed at a
known address in the pycore boot image (hex fixtures in the current
test flow). Small helpers may later be inlined instead of a PC jump.

Status values: **not implemented** (stub only), **in progress**,
**implemented** (pure-Python source ready), **in ROM** (compiled into
the boot image).

## Builtin functions

| Builtin | Description | Status | Notes |
| --- | --- | --- | --- |
| `abs` | Return the absolute value of a number. | not implemented |  |
| `aiter` | Return an asynchronous iterator for an asynchronous iterable. | not implemented |  |
| `all` | Return True if all elements of the iterable are true (or if empty). | not implemented |  |
| `anext` | Return the next item from an asynchronous iterator. | not implemented |  |
| `any` | Return True if any element of the iterable is true. | not implemented |  |
| `ascii` | Return an ASCII-only repr, escaping non-ASCII characters. | not implemented |  |
| `bin` | Convert an integer to a binary string prefixed with '0b'. | not implemented |  |
| `bool` | Return a Boolean value; subclass of int used as the Boolean type. | not implemented |  |
| `breakpoint` | Drop into the debugger at the call site (PEP 553). | not implemented |  |
| `bytearray` | Return a new mutable bytearray object. | not implemented | Seeded in image builtins dict as `BI_BYTEARRAY` / `PY_BI_BYTEARRAY`. |
| `bytes` | Return a new immutable bytes object. | not implemented |  |
| `callable` | Return True if the object appears callable. | not implemented |  |
| `chr` | Return the Unicode character for an integer code point. | not implemented |  |
| `classmethod` | Transform a method into a class method. | not implemented |  |
| `compile` | Compile source into a code object usable by exec/eval. | not implemented |  |
| `complex` | Create a complex number from real/imag or a string. | not implemented |  |
| `delattr` | Delete a named attribute from an object. | not implemented |  |
| `dict` | Create a new dictionary. | not implemented |  |
| `dir` | Return a list of valid attribute names for an object or the local scope. | not implemented |  |
| `divmod` | Return the pair (quotient, remainder) of integer division. | not implemented |  |
| `enumerate` | Return an enumerate object yielding (index, item) pairs. | not implemented |  |
| `eval` | Evaluate a Python expression from a string or code object. | not implemented |  |
| `exec` | Execute Python statements from a string or code object. | not implemented |  |
| `filter` | Construct an iterator of items for which a function returns true. | not implemented |  |
| `float` | Convert a string or number to floating point. | not implemented |  |
| `format` | Convert a value to a formatted representation ("format_spec"). | not implemented |  |
| `frozenset` | Return a new frozenset object. | not implemented |  |
| `getattr` | Return the named attribute of an object, with optional default. | not implemented |  |
| `globals` | Return the current global symbol table as a dict. | not implemented |  |
| `hasattr` | Return True if the object has the named attribute. | not implemented |  |
| `hash` | Return the hash value of an object. | not implemented |  |
| `help` | Invoke the built-in help system. | not implemented |  |
| `hex` | Convert an integer to a lowercase hexadecimal string prefixed with '0x'. | not implemented |  |
| `id` | Return the identity (unique integer) of an object. | not implemented |  |
| `input` | Read a line from stdin (after an optional prompt) and return it. | not implemented |  |
| `int` | Convert a number or string to an integer. | not implemented |  |
| `isinstance` | Return True if the object is an instance of a type or tuple of types. | not implemented |  |
| `issubclass` | Return True if a class is a subclass of a class or tuple of classes. | not implemented |  |
| `iter` | Return an iterator for an object (or call a sentinel-producing callable). | not implemented |  |
| `len` | Return the number of items in a container. | not implemented | Seeded in image builtins dict; native CALL path for `BI_LEN` / `PY_BI_LEN`. |
| `list` | Create a new list, optionally from an iterable. | not implemented |  |
| `locals` | Return the current local symbol table as a dict. | not implemented |  |
| `map` | Return an iterator that applies a function to every item of iterables. | not implemented |  |
| `max` | Return the largest item in an iterable or among arguments. | not implemented | Seeded in image builtins dict; native CALL path for `BI_MAX` / `PY_BI_MAX`. |
| `memoryview` | Return a memory view object over a bytes-like object. | not implemented |  |
| `min` | Return the smallest item in an iterable or among arguments. | not implemented |  |
| `next` | Retrieve the next item from an iterator. | not implemented |  |
| `object` | Return a new featureless object; base for all classes. | not implemented |  |
| `oct` | Convert an integer to an octal string prefixed with '0o'. | not implemented |  |
| `open` | Open a file and return a corresponding file object. | not implemented |  |
| `ord` | Return the Unicode code point for a one-character string. | not implemented |  |
| `pow` | Return base**exp, optionally modulo mod. | not implemented |  |
| `print` | Print objects to a stream (default stdout), separated by sep and ended by end. | not implemented | Seeded in image builtins dict as `BI_PRINT` / `PY_BI_PRINT`. |
| `property` | Return a property attribute with optional getter/setter/deleter. | not implemented |  |
| `range` | Return an immutable sequence of numbers (start, stop, step). | not implemented | Seeded in image builtins dict; native CALL path for `BI_RANGE` / `PY_BI_RANGE`. |
| `repr` | Return a string containing a printable representation of an object. | not implemented |  |
| `reversed` | Return a reverse iterator over a sequence. | not implemented |  |
| `round` | Round a number to a given precision in decimal digits. | not implemented |  |
| `set` | Create a new set, optionally from an iterable. | not implemented | Seeded in image builtins dict; native CALL path for `BI_SET` / `PY_BI_SET`. |
| `setattr` | Set a named attribute on an object. | not implemented |  |
| `slice` | Return a slice object representing indices for extended slicing. | not implemented |  |
| `sorted` | Return a new sorted list from an iterable. | not implemented |  |
| `staticmethod` | Transform a method into a static method. | not implemented | Image convention: `BI_STATICMETHOD` / `PY_BI_STATICMETHOD` (id 0) unwraps bound CODE. |
| `str` | Create a new string object from an object or buffer. | not implemented |  |
| `sum` | Return the sum of a start value and an iterable of numbers. | not implemented |  |
| `super` | Return a proxy object that delegates method calls to a parent or sibling class. | not implemented |  |
| `tuple` | Create a new tuple, optionally from an iterable. | not implemented |  |
| `type` | Return the type of an object, or create a new type object. | not implemented |  |
| `vars` | Return the __dict__ of an object, or locals() with no argument. | not implemented |  |
| `zip` | Iterate over several iterables in parallel, yielding tuples. | not implemented |  |

## pycore-specific helpers

These have assigned `BI_*` / `PY_BI_*` ids in the current image/RTL
but are not standalone top-level CPython builtin names. They still
get a firmware module so their ROM implementations can land alongside
the standard set.

| Builtin | Description | Status | Notes |
| --- | --- | --- | --- |
| `from_bytes` | int.from_bytes-style constructor helper (pycore BI_FROM_BYTES). | not implemented | Seeded under `int` type dict as `BI_FROM_BYTES` / `PY_BI_FROM_BYTES`. |
| `to_bytes` | int.to_bytes-style conversion helper (pycore BI_TO_BYTES). | not implemented | Seeded under `int` type dict as `BI_TO_BYTES` / `PY_BI_TO_BYTES`. |
| `list_append` | list.append method helper (pycore BI_LIST_APPEND). | not implemented | Hardware helper id `BI_LIST_APPEND` / `PY_BI_LIST_APPEND` (LIST_APPEND opcode path). |

## Source layout

Each row has a matching empty stub:

```text
pycore_firmware/builtins/<name>.py
```

Total stubs: 73

