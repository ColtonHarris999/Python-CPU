"""ROM getattr / hasattr / setattr / delattr via __dict__ special.

# pycore-inject: SEED_INSTANCE o slots=8
"""


def managed_entry():
    total = 0
    setattr(o, "x", 11)
    if getattr(o, "x") == 11:
        total += 1
    if hasattr(o, "x"):
        total += 2
    if not hasattr(o, "missing"):
        total += 4
    if getattr(o, "missing", 99) == 99:
        total += 8
    delattr(o, "x")
    if not hasattr(o, "x"):
        total += 16
    return total


managed_entry()
