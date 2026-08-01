"""list.append helper (BI_LIST_APPEND).

Hardware LIST_APPEND opcode already implements spare-capacity append and
LIST_GROW trap. This firmware entry is a semantic mirror for ROM dispatch
experiments — prefer the opcode path.
"""


def list_append(lst, value):
    lst += [value]
    return None
