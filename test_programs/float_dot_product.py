# Tests float multiply-accumulate: computes a dot product of two 3-vectors.
# a = [1.5, 2.0, -3.25],  b = [4.0, -0.5, 2.0]
# dot = 1.5*4.0 + 2.0*(-0.5) + (-3.25)*2.0 = 6.0 - 1.0 - 6.5 = -1.5
def managed_entry() -> float:
    a0 = 1.5
    a1 = 2.0
    a2 = 0.0 - 3.25   # avoid unary negation opcode; use subtraction
    b0 = 4.0
    b1 = 0.0 - 0.5
    b2 = 2.0
    return a0 * b0 + a1 * b1 + a2 * b2  # -1.5
