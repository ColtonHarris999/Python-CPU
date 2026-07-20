# Negative: TO_BOOL on a list must trap PY_TRAP_TYPE (1).
#
# CPython treats a non-empty list as truthy; PyCore has no container
# truthiness path and traps TYPE for non-INT/BOOL/FLOAT tags.  Host would
# return 1, so this uses PYCORE_IMAGE_TRAP_RUN (no EXPECTED_*).  `if lst:`
# emits TO_BOOL on the LIST handle before POP_JUMP_IF_FALSE.


def managed_entry():
    lst = [1]
    if lst:
        return 1
    return 0


managed_entry()
