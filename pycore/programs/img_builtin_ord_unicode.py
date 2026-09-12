"""BI_ORD / BI_CHR across Latin-1, BMP, and supplementary code points.

"é" is kind 1 SHORT, "中" is kind 2 LONG, "😀" is kind 4 LONG.
"""


def managed_entry():
    total = 0
    if ord("é") == 233:
        total += 1
    if ord("中") == 20013:
        total += 10
    if ord("😀") == 128512:
        total += 100
    if chr(233) == "é":
        total += 1000
    if chr(20013) == "中":
        total += 10000
    if chr(128512) == "😀":
        total += 100000
    if ord(chr(128512)) == 128512:
        total += 1000000
    return total


managed_entry()
