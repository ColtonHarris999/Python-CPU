"""int.from_bytes-style constructor (BI_FROM_BYTES).

Seeded under the ``int`` type dict; CALL → PY_TRAP_BUILTIN_CALL → excore.
Pure Python cannot read BYTES/BYTEARRAY payloads yet.
"""


def from_bytes(bytes_obj, byteorder):
    return 1 % 0
