"""Firmware round(): ties to even, int result, CPython-exact round(x, n)."""


def managed_entry():
    total = 0
    total += round(0.5)
    total += round(1.5)
    total += round(2.5)
    total += round(-2.5) + 10
    total += round(3.7)
    total += round(True)
    total += round(25, -1)
    total += round(35, -1)
    total += round(-15, -1) + 100
    total += round(7, 3)
    if round(2.675, 2) == 2.67:
        total += 1000
    if round(0.125, 2) == 0.12:
        total += 2000
    if round(0.375, 2) == 0.38:
        total += 4000
    if round(2.5, 0) == 2.0:
        total += 8000
    if round(1234.5678, -2) == 1200.0:
        total += 16000
    if round(1e22, -22) == 1e22:
        total += 32000
    if round(-0.0001, 3) == 0.0:
        total += 64000
    try:
        round(1e308 * 10.0)
    except ValueError:
        total += 128000
    return total


managed_entry()
