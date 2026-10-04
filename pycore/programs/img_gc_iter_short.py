"""GET_ITER on SHORT_STR (G9 row 12): 16 B spill word only.

A tight loop of `for ch in "ab"` so the spill allocation is what exhausts
the G7 (a) leftover run. 6000 iterators × 16 B ≈ 12 run-end aborts in 8 KB.
"""


def managed_entry():
    s = "ab"
    total = 0
    for i in range(6000):
        for ch in s:
            total = total + ord(ch)
        total = total + i % 3
    return total


managed_entry()
