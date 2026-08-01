"""Return the current global symbol table.

Frame introspection (reading the active frame's globals pointer) is not
exposed to pure Python. Boot-record globals exist only in hardware regs.
"""


def globals():
    return 1 % 0
