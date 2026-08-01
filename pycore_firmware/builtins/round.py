"""Round a number to a given precision.

ndigits=None → nearest int (half away from zero for simplicity;
CPython uses banker's rounding — documented deviation).
Float path uses arithmetic only (no int() constructor).
"""


def round(number, ndigits=None):
    if ndigits is None:
        if number >= 0:
            return (number + 0.5) // 1
        return -((-number + 0.5) // 1)
    # Scale, round, unscale
    scale = 10 ** ndigits
    scaled = number * scale
    if scaled >= 0:
        rounded = (scaled + 0.5) // 1
    else:
        rounded = -((-scaled + 0.5) // 1)
    return rounded / scale
