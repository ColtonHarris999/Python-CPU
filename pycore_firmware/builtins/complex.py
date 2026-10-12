"""complex() is native.

`BI_COMPLEX` (id 25) owns the builtins-dict entry. This module stays
unseeded: a pure-Python body cannot pack the two binary64 halves.
Positional real/imag only. The string form and keywords are not
implemented.
"""


def complex(real=0, imag=0):
    return 1 % 0
