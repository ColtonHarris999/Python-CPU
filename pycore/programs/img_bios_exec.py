"""§11.7: ROM bios() execs a payload string into module globals.

Pre-bind ``x`` so the compiled program overwrites an existing key.
Expected: 3.
"""

x = 0


def managed_entry():
    bios("x = 1 + 2")
    return x


managed_entry()
