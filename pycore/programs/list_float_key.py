"""FLOAT key on list → TYPE trap."""

def managed_entry() -> int:
    lst = [1]
    return lst[1.5]  # type: ignore
