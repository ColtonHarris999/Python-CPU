"""Create a complex number.

COMPLEX tag exists in the ALU, but pure Python can only materialize
complex literals as constants — not ``complex(re, im)`` at runtime
without a native constructor.
"""


def complex(real=0, imag=0):
    return 1 % 0
