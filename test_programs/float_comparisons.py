# Tests float comparison operators using exact IEEE-754 representable values.
# All 6 comparisons should pass → result 63.
def managed_entry() -> int:
    a = 1.5
    b = 0.5
    result = 0
    if b < a:
        result = result + 1
    if b <= a:
        result = result + 2
    if a == 1.5:
        result = result + 4
    if a != b:
        result = result + 8
    if a > b:
        result = result + 16
    if a >= 1.5:
        result = result + 32
    return result  # 63
