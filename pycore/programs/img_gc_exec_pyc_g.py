"""Source compiled at run time can name `_PYC_G`; the image must then keep
the collector tracing it.

The program never names `_PYC_G` itself, so before review round 2 the image
kept the compiler-cleanup descriptor and the collector premarked `_PYC_G`
without tracing it. The list stored there by `exec` was then freed while
reachable. The builder now also reads the identifiers in the string
constants of a program that compiles source at run time, including strings
inside tuple constants such as `put`'s loop tuple (B27, B29).

# pycore-expect: 27
"""


def churn(n):
    junk = None
    i = 0
    while i < n:
        junk = [i, i, i, i, i, i, i, i]
        i = i + 1
    return junk


def put():
    for src in ("_PYC_G['gc_probe'] = [7, 8, 9]", "0"):
        exec(src)


def get():
    total = 0
    for src in ("_PYC_G['gc_probe'][0] + _PYC_G['gc_probe'][1]", "_PYC_G['gc_probe'][2] + 3"):
        total = total + eval(src)
    return total


def managed_entry():
    put()
    churn(150)
    _bi_gc_collect()
    churn(150)
    return get()


managed_entry()
