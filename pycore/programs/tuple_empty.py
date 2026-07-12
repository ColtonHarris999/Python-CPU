"""Empty BUILD_TUPLE then continue allocating.

Note: CPython emits LOAD_CONST for `()`, so the committed hex is hand-assembled
with BUILD_TUPLE 0 (see tuple_empty.hex). Equivalent intent:

    t = <BUILD_TUPLE 0>
    lst = [9]
    return lst[0]
"""
