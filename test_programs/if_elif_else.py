# Tests if / elif / else branching chains.
# x = 42 lands in the third branch (> 25 but not > 50).
def managed_entry() -> int:
    x = 42
    if x > 100:
        result = 1
    elif x > 50:
        result = 2
    elif x > 25:
        result = 3
    else:
        result = 4
    return result  # 3
