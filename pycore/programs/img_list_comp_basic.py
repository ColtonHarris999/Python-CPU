"""List comprehension from real compile() — Track C.

Builds ``[x for x in range(5)]`` (emits LOAD_FAST_AND_CLEAR, LIST_APPEND,
exception-table RERAISE cleanup) then sums the result. Needs two-core for
LIST_APPEND grow.
"""


def managed_entry():
    xs = [x for x in range(5)]
    total = 0
    for v in xs:
        total += v
    return total


managed_entry()
