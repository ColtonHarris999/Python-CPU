"""In-place list mutation during iteration (re-read ob_item each FOR_ITER).

When x==1, xs[2] is rewritten to 10 before that slot is visited.
Expected result: 1 + 2 + 10 = 13.
"""


def managed_entry():
    a, b, c = 1, 2, 3
    xs = [a, b, c]
    total = 0
    for x in xs:
        total += x
        if x == 1:
            xs[2] = 10
    return total


managed_entry()
