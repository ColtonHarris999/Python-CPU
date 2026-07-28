"""SET_ADD then CONTAINS_OP (hand-assembled via SET_ADD_SEQ inject).

Host path uses real set.add for expected value; hardware injects BUILD_SET 0
+ SET_ADD. Expected: 1+1+1 = 3 (1 in, 2 in, 3 not in).
"""

# pycore-inject: SET_ADD_SEQ managed_entry 1 2 MODE=CONTAINS


def managed_entry():
    s = set()
    s.add(1)
    s.add(2)
    n = 0
    if 1 in s:
        n = n + 1
    if 2 in s:
        n = n + 1
    if 3 not in s:
        n = n + 1
    return n


managed_entry()
