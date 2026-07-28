"""UNPACK_EX: starred unpack from LIST and TUPLE.

Build source list from variables (avoids LIST_EXTEND which needs excore).
Tests:
- a, *b, c = [v1..v5]  → a=1, b=[2,3,4], c=5; read b via subscript
- *d, e = (10, 20, 30) → d=[10,20], e=30; read d via subscript
Expected: a + b[0]+b[1]+b[2] + c + d[0]+d[1] + e = 1+2+3+4+5+10+20+30 = 75
"""


def managed_entry():
    v1 = 1
    v2 = 2
    v3 = 3
    v4 = 4
    v5 = 5
    a, *b, c = [v1, v2, v3, v4, v5]
    *d, e = (10, 20, 30)
    return a + b[0] + b[1] + b[2] + c + d[0] + d[1] + e


managed_entry()
