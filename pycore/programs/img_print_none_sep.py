"""None and SHORT_STR mixed with custom sep."""


def managed_entry():
    print(None, "x", None, sep=":")
    return 0


managed_entry()
