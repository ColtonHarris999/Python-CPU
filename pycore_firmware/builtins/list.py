"""Build a list, optionally from an iterable.

Uses LIST_EXTEND (NB_INPLACE_ADD) per element — non-empty extend needs
excore (PY_TRAP_LIST_EXTEND). No *iterable call form (CALL_FUNCTION_EX).
"""


def list(iterable=None):
    out = []
    if iterable is None:
        return out
    for x in iterable:
        out += [x]
    return out
