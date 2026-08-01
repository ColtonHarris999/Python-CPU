"""BI_LEN on inline PY_TAG_RANGE."""


def managed_entry():
    return len(range(2, 10, 3))  # 2,5,8 → 3


managed_entry()
