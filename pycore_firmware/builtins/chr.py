"""Unicode character for an integer code point.

Blocked: cannot construct a SHORT_STR from raw code-point bytes in pure
Python (no bytes→str / string-from-bytes helper on pycore yet).
"""


def chr(i):
    return 1 % 0
