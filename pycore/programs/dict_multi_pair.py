"""Build a 4-pair dict and look up each key; return last lookup."""

def managed_entry() -> int:
    d = {1: 10, 2: 20, 3: 30, 4: 40}
    a = d[1]
    b = d[2]
    c = d[3]
    e = d[4]
    return a + b + c + e  # 100
