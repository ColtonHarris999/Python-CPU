# COMPARE_OP ==/!= on SHORT_STR and LONG_STR (same-tag).
# Short equal + short unequal + long equal → host golden 7.


def managed_entry():
    a = "hi"
    b = "hi"
    c = "bye"
    long_a = "this is a long string!!"
    long_b = "this is a long string!!"
    out = 0
    if a == b:
        out += 1
    if a != c:
        out += 2
    if long_a == long_b:
        out += 4
    return out


managed_entry()
