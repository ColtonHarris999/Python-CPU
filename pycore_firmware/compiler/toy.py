# Toy two-function package for compiler_design.md step D.
# One helper calls the other through ``_PYC_G`` after ``_bi_exec_globals``.


def _pyc_inc(x):
    return x + 1


def _pyc_add(a, b):
    return a + b
