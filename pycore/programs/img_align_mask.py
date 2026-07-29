# Alignment-style mask: flags & ~mask via UNARY_INVERT + BINARY_OP AND.
# 0xF & ~3 == 12.


def managed_entry():
    m = 3
    flags = 0xF
    return flags & ~m


managed_entry()
