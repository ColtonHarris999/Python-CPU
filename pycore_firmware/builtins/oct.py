"""Convert an integer to a '0o'-prefixed octal string."""


def oct(x):
    neg = 0
    n = x
    if n < 0:
        neg = 1
        n = -n
    if n == 0:
        if neg:
            return "-0o0"
        return "0o0"
    digits = ""
    while n > 0:
        d = n % 8
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
        else:
            ch = "7"
        digits = ch + digits
        n = n // 8
    if neg:
        return "-0o" + digits
    return "0o" + digits
