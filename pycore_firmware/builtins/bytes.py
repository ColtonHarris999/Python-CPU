"""Immutable bytes object.

PY_TAG_BYTES exists; runtime constructor / builders are not exposed to
pure Python yet (see bytearray / from_bytes plans).
"""


def bytes(source=None):
    return 1 % 0
