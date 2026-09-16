"""Nested list handle round-trip. Expected: INT 7."""


def managed_entry():
    inner = [7]
    outer = [inner]
    return outer[0][0]


managed_entry()
