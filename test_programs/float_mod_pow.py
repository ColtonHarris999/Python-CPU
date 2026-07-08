# Tests float modulo and power operators.
def managed_entry() -> float:
    a = 10.0
    b = 3.0
    r = a % b         # 1.0 (10 mod 3)
    p = 2.0 ** 10.0   # 1024.0
    return r + p      # 1025.0
