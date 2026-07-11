# Tests float arithmetic: +, -, *, true division (/), floor division (//)
def managed_entry() -> float:
    a = 10.0
    b = 4.0
    c = a + b    # 14.0
    d = c - 3.5  # 10.5
    e = d * 2.0  # 21.0
    f = e / 4.0  # 5.25
    g = e // 4.0 # 5.0
    return f + g  # 10.25
