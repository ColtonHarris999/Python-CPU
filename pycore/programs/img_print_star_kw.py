"""print(*xs, sep=) via CALL_FUNCTION_EX + kwargs."""


def managed_entry():
    xs = (1, 2, 3)
    print(*xs, sep="-")
    return 0


managed_entry()
