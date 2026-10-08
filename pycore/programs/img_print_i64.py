"""Print integers outside the 32-bit range (A4).

The excore sink used only the low 32 bits. The pycore formatter emits
the full signed 64-bit decimal, including the minimum value.
"""


def managed_entry():
    print(4294967296)
    print(-4294967296)
    print(-9223372036854775808)
    return 0


managed_entry()
