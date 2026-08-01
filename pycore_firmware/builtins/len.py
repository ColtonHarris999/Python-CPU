"""Miss / protocol path for ``len``.

Hardware ``BI_LEN`` (CALL FSM) handles list/tuple/dict/set/str headers.
This ROM body is only for objects that expose ``__len__``.
Do not recount containers with a for-loop — that races the fast path.
"""


def len(obj):
    return obj.__len__()
