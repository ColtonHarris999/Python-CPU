# Tests comparison operators that produce Bool results and their use in branches.
def managed_entry() -> int:
    x = 10
    y = 20
    score = 0

    lt_result = x < y    # True
    gt_result = x > y    # False
    eq_result = x == x   # True
    ne_result = x != y   # True

    if lt_result:
        score = score + 1
    if gt_result:
        score = score + 2
    if eq_result:
        score = score + 4
    if ne_result:
        score = score + 8
    return score  # 1 + 0 + 4 + 8 = 13
