# UNPACK_EX on a TUPLE local: a,*b,c = (1,2,3,4) -> 1 + 4 + len([2,3]) = 7.


def managed_entry():
    a, *b, c = (1, 2, 3, 4)
    return a + c + len(b)


managed_entry()
