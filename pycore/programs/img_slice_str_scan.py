"""The tokenizer's access pattern: walk a line and slice out tokens.

Mirrors `line[start:pos]` from PyPy's tokenizer, which the port needs at 14
separate sites (Plan 1 §2.3).
"""


def managed_entry():
    line = "ab cd efg"
    total = 0
    start = 0
    pos = 0
    n = len(line)
    while pos <= n:
        at_end = pos == n
        if at_end:
            sep = True
        else:
            sep = line[pos] == " "
        if sep:
            if pos > start:
                total += len(line[start:pos]) * 10
                total += 1
            start = pos + 1
        pos += 1
    return total


managed_entry()
