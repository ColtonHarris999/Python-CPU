def managed_entry() -> int:
    value = 17
    step = 6

    value += step
    value -= 3
    value *= 2
    value //= 5
    value %= 3
    value **= 3
    value <<= 2
    value >>= 1
    value |= 9
    value &= 14
    value ^= 11

    return value
