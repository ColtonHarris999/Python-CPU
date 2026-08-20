"""exec(code, non-dict) is PY_TRAP_TYPE (1). CPython raises TypeError.

# pycore-inject: SEED_CODE payload mode=exec source="x = 1"
"""


def managed_entry():
    return exec(payload, 5)


managed_entry()
