"""Unicode code point of a one-character string.

Implemented natively as ``BI_ORD`` (id 10) in the CALL FSM, which owns the
``ord`` entry in the boot builtins dict. A one-character string is always a
SHORT_STR (every string of <= 15 bytes is), so the encoded bytes sit inline in
the handle and the UTF-8 decode needs no ``string_mem`` access — one cycle, no
dmem traffic.

Reading payload bytes as an integer is precisely the primitive that pure Python
lacks, so there is no miss path to fall back to. This body is never seeded; it
raises so a mis-wired builtins dict fails loudly instead of silently returning
a wrong code point.
"""


def ord(c):
    # Unreachable: BI_ORD owns the dict entry.
    raise TypeError
