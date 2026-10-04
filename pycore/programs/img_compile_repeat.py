"""R4: compile the same tiny source 8 times (compiler_design.md §5.7).

Host CPython has no bump cursor, so the golden is stated directly: return 1
when all eight compiles succeed. Mark subtraction is only valid inside one
epoch (gc_plan.md §5.4); G7 (b) collections between the two marks used to
return the epoch delta (0x3200001440). Phase 4 re-points leak measurement
at `_bi_heap_free()` after `_bi_gc_collect()`.

# pycore-expect: 1
"""


def managed_entry():
    i = 0
    while i < 8:
        compile("1 + 2", "<s>", "eval")
        i = i + 1
    return 1


managed_entry()
