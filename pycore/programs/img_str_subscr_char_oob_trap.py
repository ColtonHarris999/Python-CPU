"""Character-count bound: "e-acute" is 1 character but 2 bytes.

len(s) is a BYTE count, so the CP_INIT byte-length check admits index 1; the
walk then runs off the end and must raise PY_TRAP_MEM_FAULT (trap 7) rather
than returning a partial byte or type-trapping.
"""


def managed_entry():
    s = "é"
    return s[1]


managed_entry()
