"""Drop into the debugger (PEP 553).

No ``sys.breakpointhook`` / debugger source on pycore.
"""


def breakpoint():
    return 1 % 0
