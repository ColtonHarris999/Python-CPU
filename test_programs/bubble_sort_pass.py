# Tests a single-pass compare-and-swap (bubble sort one pass) over 4 elements
# using many local variables and if-branching. Returns sum of sorted elements.
def managed_entry() -> int:
    a0 = 5
    a1 = 1
    a2 = 4
    a3 = 2

    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp
    if a1 > a2:
        tmp = a1
        a1 = a2
        a2 = tmp
    if a2 > a3:
        tmp = a2
        a2 = a3
        a3 = tmp
    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp
    if a1 > a2:
        tmp = a1
        a1 = a2
        a2 = tmp
    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp

    # After sorting [5,1,4,2] → [1,2,4,5]
    # Check order is correct and return sum
    result = 0
    if a0 <= a1:
        result = result + 1
    if a1 <= a2:
        result = result + 2
    if a2 <= a3:
        result = result + 4
    return result  # 7 (all three comparisons pass)
