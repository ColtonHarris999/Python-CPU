"""Absolute value.

INT/BOOL/FLOAT use `<` and `UNARY_NEGATIVE`. COMPLEX (tag 3) is
`_bi_cabs`, the hardware hypot. Other tags still TYPE-trap on `<`.
"""


def abs(x):
    if _bi_code_kind(x) == 3:
        return _bi_cabs(x)
    if x < 0:
        return -x
    return x
