"""exec() a precompiled module-mode code object; its STORE_NAME hits globals.

# pycore-inject: SEED_CODE snippet mode=exec source="ex_x = 1 + 2\nex_y = ex_x * 10"
"""

ex_x = 0
ex_y = 0


def managed_entry():
    exec(snippet)
    return ex_x + ex_y


managed_entry()
