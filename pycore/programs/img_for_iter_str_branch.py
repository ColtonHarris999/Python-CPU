"""String loop values remain usable by a branching loop body."""


def managed_entry():
    score = 0
    for c in "135":
        if c == "1":
            score += 100
        if c == "3":
            score += 10
        if c == "5":
            score += 1
    return score


managed_entry()
