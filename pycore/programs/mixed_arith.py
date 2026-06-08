def managed_entry() -> float:
    count = 7
    scale = 2.5
    enabled = True
    offset = 3
    return (count / offset) + (enabled * scale)
