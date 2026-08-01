"""Stringify INT/BOOL/None; STR identity is a tag-probe blocker.

``_str_int`` implements signed decimal formatting with string concat.
"""


def str(obj=""):
    if obj is True:
        return "True"
    if obj is False:
        return "False"
    if obj is None:
        return "None"
    return _str_int(obj)


def _str_int(n):
    if n == 0:
        return "0"
    neg = 0
    x = n
    if x < 0:
        neg = 1
        x = -x
    digits = ""
    while x > 0:
        d = x % 10
        if d == 0:
            ch = "0"
        elif d == 1:
            ch = "1"
        elif d == 2:
            ch = "2"
        elif d == 3:
            ch = "3"
        elif d == 4:
            ch = "4"
        elif d == 5:
            ch = "5"
        elif d == 6:
            ch = "6"
        elif d == 7:
            ch = "7"
        elif d == 8:
            ch = "8"
        else:
            ch = "9"
        digits = ch + digits
        x = x // 10
    if neg:
        return "-" + digits
    return digits
