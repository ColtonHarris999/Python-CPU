"""The payload reads an existing global and writes a new one.

# pycore-inject: SEED_CODE snippet mode=exec source="rw_out = rw_in + 5"
"""

rw_in = 30
rw_out = 0


def managed_entry():
    exec(snippet)
    return rw_out


managed_entry()
