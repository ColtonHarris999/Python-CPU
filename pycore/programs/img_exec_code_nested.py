"""A payload that itself calls exec() on a second payload.

# pycore-inject: SEED_CODE inner mode=exec source="ne_b = ne_a + 1"
# pycore-inject: SEED_CODE outer mode=exec source="ne_a = 4\nexec(inner)"
"""

ne_a = 0
ne_b = 0


def managed_entry():
    exec(outer)
    return ne_a * 10 + ne_b


managed_entry()
