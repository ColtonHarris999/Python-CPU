# Tests while loop with if/else branching inside the loop body.
# Counts Collatz sequence steps from n=25 to reach 1.
# Exercises: while + comparison, if/else, mod, floor-div, multiply, add.
def managed_entry() -> int:
    n = 25
    steps = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = n * 3 + 1
        steps = steps + 1
    return steps  # 23
