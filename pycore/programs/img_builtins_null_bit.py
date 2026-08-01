"""LEGB-B: LOAD_GLOBAL with null bit set after a builtins hit.

`max(3, 7)` emits LOAD_GLOBAL (null+name) then CALL; null-bit push must
work when the value came from the builtins dict fallback.
"""


def managed_entry():
    return max(3, 7)


managed_entry()
