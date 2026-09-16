"""R4: compile the same tiny source 8 times inside one mark (compiler_design.md §5.7).

The compiler leaks its working set. This pins the watermark so a silent OOM
becomes a test failure. Host CPython has no bump cursor, so the golden is
stated directly: return 1 when used bytes stay under CAP.

# pycore-expect: 1
"""

CAP = 400000


def managed_entry():
    hm = _bi_heap_mark()
    i = 0
    while i < 8:
        compile("1 + 2", "<s>", "eval")
        i = i + 1
    used = _bi_heap_mark() - hm
    if used <= 0:
        return 0
    if used <= CAP:
        return 1
    return used


managed_entry()
