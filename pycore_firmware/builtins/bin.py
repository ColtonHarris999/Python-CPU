"""Convert an integer to a '0b'-prefixed binary string."""


def bin(x):
    neg = 0
    n = x
    if n < 0:
        neg = 1
        n = -n
    if n == 0:
        if neg:
            return "-0b0"
        return "0b0"
    digits = ""
    while n > 0:
        bit = n % 2
        if bit == 0:
            digits = "0" + digits
        else:
            digits = "1" + digits
        n = n // 2
    if neg:
        return "-0b" + digits
    return "0b" + digits
