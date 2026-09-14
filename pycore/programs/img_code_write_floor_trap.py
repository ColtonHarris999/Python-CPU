"""_bi_code_patch below code_ram_floor_r traps MEM_FAULT (7).

Slot 0x1FFF sits in ROM, one below the default write floor 0x2000.
"""


def managed_entry():
    _bi_code_patch(8191, (0 << 8) | 128)
    return 0


managed_entry()
