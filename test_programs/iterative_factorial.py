# Tests iterative computation with a while loop that accumulates a product.
# Computes 6! = 720 without function calls so preprocess.py can compile it.
# Exercises: while loop, multiply in a loop, comparison with a constant.
def managed_entry() -> int:
    result = 1
    n = 6
    while n > 1:
        result = result * n
        n = n - 1
    return result  # 720
