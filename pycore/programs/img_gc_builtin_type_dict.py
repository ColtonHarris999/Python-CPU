"""A list stored in a builtin type's dict survives an idle collection.

Review round 1, finding 4. An idle collection premarks the builtins dict
header instead of walking its table; `int` is reachable only through it, and
`int.__dict__` is a mutable static dict. The image lists such builtins
values as extra roots so the list below stays live. CPython refuses the
store (`mappingproxy`), hence the stated result.
# pycore-expect: 672
"""


def churn(n):
    keep = None
    for i in range(n):
        keep = [i, (i, i + 1), [i, i + 2, i, i]]
    return keep


def managed_entry():
    a = 7
    d = int.__dict__
    d["from_bytes"] = [a, a + 1, a + 2, [a * 0 + 100, 200, 300]]
    d = None
    total = 0
    for r in range(3):
        _bi_gc_collect()
        churn(200)
        v = int.__dict__["from_bytes"]
        total = total + v[0] + v[1] + v[2] + v[3][r]
    return total


managed_entry()
