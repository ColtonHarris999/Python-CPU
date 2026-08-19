"""Error reporting convention while OBK_EXCEPTION.args is always empty.

Calling a type builds an OBK_INSTANCE, not an exception, so SyntaxError("msg")
is not available yet (Plan 1 P7 step 3). Until RAISE_VARARGS can carry an args
tuple, firmware records the position/message in globals immediately before
raising and the handler reads them back. This pins that convention.
"""

_err_pos = 0


def managed_entry():
    global _err_pos
    total = 0
    try:
        _err_pos = 42
        raise SyntaxError
    except SyntaxError:
        total += _err_pos
    return total


managed_entry()
