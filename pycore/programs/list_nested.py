"""Nested list handle round-trip."""

def managed_entry() -> int:
    inner = [7]
    outer = [inner]
    return outer[0][0]
