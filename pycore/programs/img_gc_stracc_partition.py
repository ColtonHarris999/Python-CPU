"""STRACC partition/rpartition (G9 row 34) as the only heap producer.

Pieces are longer than 15 bytes so each side is a LONG_STR. No concat/join
in the loop, so NEED_HEAP credits stracc14.3 / stracc14.4.
"""


def managed_entry():
    text = ("left-payload-abcdefghijklmnop-SEP-"
            "right-payload-abcdefghijklmnop")
    total = 0
    keep = ("", "", "")
    for i in range(500):
        if i % 2 == 0:
            parts = text.partition("SEP")
        else:
            parts = text.rpartition("SEP")
        keep = parts
        total = total + len(parts[0]) + len(parts[1]) + len(parts[2])
    return total + len(keep[2])


managed_entry()
