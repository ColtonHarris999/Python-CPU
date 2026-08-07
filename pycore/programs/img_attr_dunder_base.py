"""LOAD_ATTR __base__ walks tp_base on OBK_TYPE.

# pycore-inject: SEED_TYPE Base
# pycore-inject: SEED_TYPE Child base=Base
# pycore-inject: SEED_TYPE Other
"""


def managed_entry():
    total = 0
    if Child.__base__ is Base:
        total += 1
    if Child.__base__ is not Other:
        total += 2
    if Child.__base__ is not Child:
        total += 4
    return total


managed_entry()
