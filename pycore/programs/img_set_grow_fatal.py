"""Fourth SET_ADD on empty BUILD_SET → fatal SET_GROW (13) without excore.

Empty BUILD_SET allocates 4 slots; inserts 0,1,2 ok; 3rd new at used=3
needs grow (used*3 >= slots*2).
"""

# pycore-inject: SET_ADD_SEQ managed_entry 0 1 2 3 MODE=RET


def managed_entry():
    return 0


managed_entry()
