"""Interned long string (>15 bytes) as dict key."""

def managed_entry() -> int:
    k = "abcdefghijklmnop"  # 16 bytes
    d = {k: 77}
    return d[k]
