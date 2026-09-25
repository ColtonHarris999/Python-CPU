"""_bi_code_alloc past CODE_RAM_SLOT_LIMIT traps MEM_FAULT (7).

From floor 0x2000, 131073 (0x20001) slots would end at 0x22001, past the
0x22000 limit (131072 writable slots).
"""


def managed_entry():
    return _bi_code_alloc(131073)


managed_entry()
