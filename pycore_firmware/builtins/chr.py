"""Unicode character for an integer code point.

Implemented natively as ``BI_CHR`` (id 11) in the CALL FSM, which owns the
``chr`` entry in the boot builtins dict. The 1-4 UTF-8 bytes are encoded inline
into the resulting SHORT_STR handle — one cycle, no allocation.

Rejects code points above U+10FFFF and, unlike CPython, lone surrogates
(U+D800..U+DFFF): they have no well-formed UTF-8 encoding and every PyCore
string path assumes UTF-8. Both raise ``PY_TRAP_TYPE``.

Building a string from raw bytes is precisely the primitive that pure Python
lacks, so there is no miss path. This body is never seeded; it raises so a
mis-wired builtins dict fails loudly.
"""


def chr(i):
    # Unreachable: BI_CHR owns the dict entry. Fatal PY_TRAP_RAISE.
    raise 1
