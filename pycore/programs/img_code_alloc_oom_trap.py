"""_bi_code_alloc past CODE_RAM_SLOT_LIMIT traps MEM_FAULT (7).

From floor 0x2000, 0x8001 slots would end at 0xA001, past the 0xA000 limit.
"""


def managed_entry():
    return _bi_code_alloc(32769)


managed_entry()
