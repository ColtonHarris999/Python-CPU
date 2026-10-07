"""GC: a deep live chain must not make collection fail on a mostly empty heap.

100,000 nodes `(payload, next)`. Depth-first marking scans a node, pushes
its payload list and the next node, pops the next node first, and so leaves
one payload per level on the mark stack: far more than the stack holds.
When the stack is full the node being scanned goes to the rescan list and
is scanned again once the stack drains. The program then checks that every
payload survived.

# pycore-expect: 1
"""


def managed_entry():
    n = 100000
    head = None
    i = 0
    while i < n:
        head = ([i], head)
        i = i + 1
    try:
        _bi_gc_collect()
    except MemoryError:
        return 2
    junk = [None] * 1000
    i = 0
    while i < 1000:
        junk[i] = [-1]
        i = i + 1
    node = head
    i = n - 1
    while node is not None:
        if node[0][0] != i:
            return 100
        node = node[1]
        i = i - 1
    if i != -1:
        return 101
    return 1


managed_entry()
