# Negative: TO_BOOL on a str must trap PY_TRAP_TYPE (1).
#
# CPython treats a non-empty str as truthy; PyCore has no string truthiness
# path and traps TYPE for non-INT/BOOL/FLOAT tags.  Host would return 1, so
# this uses PYCORE_IMAGE_TRAP_RUN (no EXPECTED_*).  `if s:` emits TO_BOOL on
# the SHORT_STR local before POP_JUMP_IF_FALSE.


def managed_entry():
    s = "hi"
    if s:
        return 1
    return 0


managed_entry()
