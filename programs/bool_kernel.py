def managed_entry() -> int:
    x = 9
    y = 3
    gt = x > y
    lt = x < y
    both = gt and (not lt)
    score = x + y
    if both:
        score = score + 5
    else:
        score = score - 5
    return score
