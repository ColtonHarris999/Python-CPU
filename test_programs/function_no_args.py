# Tests a simple function call with no arguments.
# managed_entry must be first so it lands at the program entry point (slot 0).
def managed_entry() -> int:
    return get_answer()


def get_answer() -> int:
    return 42
