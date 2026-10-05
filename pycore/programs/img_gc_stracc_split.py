"""GC: STRACC split only (gc_plan.md §6.4 / G9 row 35).

Pieces are longer than 15 bytes (LONG_STR). The loop does not concat or
join, so a NEED_HEAP abort credits stracc14.0 rather than CONCAT.
"""


def managed_entry():
    text = ("0123456789abcdef-0123456789abcdef-0123456789abcdef-"
            "0123456789abcdef-0123456789abcdef-0123456789abcdef-"
            "0123456789abcdef-0123456789abcdef")
    total = 0
    parts = None
    for rnd in range(160):
        parts = text.split("-")
        total = total + len(parts) + len(parts[rnd % 8]) + len(parts[len(parts) - 1])
    return total


managed_entry()
