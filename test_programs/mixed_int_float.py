# Tests promotion from int/bool to float in mixed-type arithmetic.
# Also tests the existing mixed_arith scenario: (count / offset) + (enabled * scale).
def managed_entry() -> float:
    count = 7
    scale = 2.5
    enabled = True
    offset = 3
    a = count / offset    # 2.333...  true division int/int → float
    b = enabled * scale   # 1 * 2.5 = 2.5
    return a + b          # ~4.833...
