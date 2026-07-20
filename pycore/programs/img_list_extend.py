"""Image-boot program exercising LIST_EXTEND via list-display unpack.

compile() emits LIST_EXTEND for `[1, 2, *x]` and `[*a, *b]`. BUILD_LIST
always allocates capacity == length, so the first non-empty extend hits
PY_TRAP_LIST_EXTEND and needs the excore (two-core / EXCORE_EN=1).

Returns 1+2+10+20+3+4 = 40.
"""


def managed_entry():
    x = [10, 20]
    y = [1, 2, *x]
    a = [3]
    b = (4,)
    z = [*a, *b]
    return y[0] + y[1] + y[2] + y[3] + z[0] + z[1]


managed_entry()
