"""Convert an integer to a '0x'-prefixed lowercase hex string."""


def hex(x):
    neg = 0
    n = x
    if n < 0:
        neg = 1
        n = -n
    if n == 0:
        if neg:
            return "-0x0"
        return "0x0"
    digits = ""
    while n > 0:
        d = n % 16
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
        elif d == 9:
            ch = "9"
        elif d == 10:
            ch = "a"
        elif d == 11:
            ch = "b"
        elif d == 12:
            ch = "c"
        elif d == 13:
            ch = "d"
        elif d == 14:
            ch = "e"
        else:
            ch = "f"
        digits = ch + digits
        n = n // 16
    if neg:
        return "-0x" + digits
    return "0x" + digits
