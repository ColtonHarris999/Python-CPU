"""try/except StopIteration via table dispatch + CHECK_EXC_MATCH (§10 step 5)."""


def managed_entry():
    try:
        raise StopIteration
    except StopIteration:
        return 7


managed_entry()
