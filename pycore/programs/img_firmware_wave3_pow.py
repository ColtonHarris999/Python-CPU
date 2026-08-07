"""Extra pow / divmod / min coverage (single-core). Host golden: 169."""


def managed_entry():
    total = 0
    total += pow(2, 0)
    total += pow(5, 1)
    total += pow(2, 10, 1000)
    q, r = divmod(100, 7)
    total += q * 10 + r
    total += min(0, 0)
    total += min(-3, 2)
    return total


managed_entry()
