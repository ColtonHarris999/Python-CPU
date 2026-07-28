# Negative: TO_BOOL on None must trap PY_TRAP_TYPE (1).
#
# CPython treats None as falsy; PyCore has no None truthiness path and traps
# TYPE for non-INT/BOOL/FLOAT tags.  Host would return 0, so this uses
# PYCORE_IMAGE_TRAP_RUN (no EXPECTED_*).


def managed_entry():
    x = None
    if x:
        return 1
    return 0


managed_entry()
