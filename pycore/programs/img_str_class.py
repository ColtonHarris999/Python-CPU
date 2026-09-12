"""LOAD_ATTR __class__ on SHORT_STR / LONG_STR returns the seeded str type.

Unblocks ROM isinstance("x", str) (levendist ``_require_str``).
"""


def managed_entry():
    total = 0
    s = "ab"
    if s.__class__ is str:
        total += 1
    if isinstance(s, str):
        total += 2
    if not isinstance(s, int):
        total += 4
    long_s = "abcdefghijklmnop"
    if isinstance(long_s, str):
        total += 8
    if long_s.__class__ is str:
        total += 16
    return total


managed_entry()
