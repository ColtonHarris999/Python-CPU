"""Extra coverage for ROM bin/hex/oct edge cases (single-core).

Host golden: 111.
"""


def managed_entry():
    total = 0
    if bin(0) == "0b0":
        total += 1
    if bin(-2) == "-0b10":
        total += 10
    if hex(0) == "0x0":
        total += 20
    if hex(255) == "0xff":
        total += 30
    if oct(0) == "0o0":
        total += 40
    if oct(-1) == "-0o1":
        total += 10
    return total


managed_entry()
