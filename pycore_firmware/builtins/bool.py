"""Convert a value to Bool.

PyCore note: uses TO_BOOL; supports INT/BOOL/FLOAT/STR only.
Does not subclass int (no type object fabrication yet).
"""


def bool(x):
    if x:
        result = True
        return result
    result = False
    return result
