"""Absolute value — pycore-runnable for INT/BOOL/FLOAT (UNARY_NEGATIVE)."""


def abs(x):
    if x < 0:
        return -x
    return x
