# Tests all integer binary arithmetic operators: +, -, *, //, %, **
# Each partial result feeds the next so a single wrong operation changes the return.
def managed_entry() -> int:
    a = 100
    b = 7
    c = a + b       # 107
    d = c - 20      # 87
    e = d * 3       # 261
    f = e // 10     # 26
    g = e % 10      # 1
    h = 2 ** 8      # 256
    return f + g + h  # 26 + 1 + 256 = 283
