# Tests a sequence of local-variable arithmetic steps (two-local loads throughout).
# Computes the same result as the nested_calls.py multi-function version (74)
# but inlined into a single function so preprocess.py can compile it.
# step(n) = 4*n - 1 ;  managed_entry = step(4) + step(step(4)) = 15 + 59 = 74
def managed_entry() -> int:
    # Inline step(4): double=8, increment=9, double=18, subtract3=15
    n = 4
    a = n * 2       # 8
    b = a + 1       # 9
    c = b * 2       # 18
    step_n = c - 3  # 15

    # Inline step(step_n): double=30, increment=31, double=62, subtract3=59
    d = step_n * 2  # 30
    e = d + 1       # 31
    f = e * 2       # 62
    step_m = f - 3  # 59

    return step_n + step_m  # 74
