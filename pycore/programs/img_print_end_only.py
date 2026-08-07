"""Override end= only; sep stays default (space)."""


def managed_entry():
    print(1, 2, end="|")
    print(3)
    return 0


managed_entry()
