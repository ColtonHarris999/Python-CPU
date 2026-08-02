"""SET_UPDATE with a TUPLE source — pycore-only bulk path.

`{*t, *u}` where ``u`` is a tuple lowers to BUILD_SET + SET_UPDATE with a TUPLE
iterable. Tuples carry no contamination bit, so the excore SET_UPDATE fast path
(LIST/SET/DICT only) cannot own them — pycore must grow the destination set in
place and fold in every tuple element. Seeding the set with one element and
adding a two-element tuple crosses the 2/3 load factor, so the grow+rehash loop
runs as well as the element inserts. Element 1 appears in both operands, so the
duplicate-skip path is exercised too.
"""


def managed_entry():
    t = {1}
    u = (1, 2, 3)
    s = {*t, *u}
    n = 0
    if 1 in s:
        n = n + 1
    if 2 in s:
        n = n + 1
    if 3 in s:
        n = n + 1
    if 4 in s:
        n = n + 1
    return n * 10 + len(s)


managed_entry()
