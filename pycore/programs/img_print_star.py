"""print(*xs) via CALL_FUNCTION_EX."""


def managed_entry():
    xs = (10, 20, 30)
    print(*xs)
    return 0


managed_entry()
