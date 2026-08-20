"""An exception raised in a callee does NOT reach a caller's handler: trap 17.

RAISE_VARARGS walks only the raising code object's own exception table; there is
no unwind across frames. CPython would catch this. Pinned so the limitation is
visible to anyone writing firmware error paths -- keep the raise and its handler
in one frame.
"""


def fail():
    raise ValueError


def managed_entry():
    try:
        fail()
    except ValueError:
        return 1
    return 0


managed_entry()
