"""exec() returns None regardless of what the payload's body evaluates to.

# pycore-inject: SEED_CODE snippet mode=exec source="rn_v = 7"
"""

rn_v = 0


def managed_entry():
    out = exec(snippet)
    total = rn_v
    if out is None:
        total += 100
    return total


managed_entry()
