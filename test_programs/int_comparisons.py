# Tests all integer comparison operators: <, <=, ==, !=, >, >=
# Each passing comparison adds a power of 2 to result; all 6 should pass → 63.
def managed_entry() -> int:
    a = 42
    b = 17
    result = 0
    if b < a:
        result = result + 1
    if b <= a:
        result = result + 2
    if a == 42:
        result = result + 4
    if a != b:
        result = result + 8
    if a > b:
        result = result + 16
    if a >= 42:
        result = result + 32
    return result  # 63
