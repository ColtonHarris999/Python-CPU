"""GC gen Phase 0: a deep old chain whose tail gets young nodes.

A singly linked chain of ~300 nodes survives a collection (old), then fresh
nodes are linked onto its tail and payloads deep in the chain are replaced
with young objects. A second collection runs before the whole chain is walked.
"""


class Node:
    def __init__(self, val, nxt):
        self.val = val
        self.nxt = nxt


def managed_entry():
    head = Node(("old-node", 0), None)
    tail = head
    for i in range(1, 300):
        n = Node(("old-node", i), None)
        tail.nxt = n
        tail = n
    _bi_gc_collect()
    for i in range(300, 320):
        n = Node(["young-tail-node-" + str(i), i], None)
        tail.nxt = n
        tail = n
    n = None
    mid = head
    for i in range(150):
        mid = mid.nxt
    mid.val = ["young-mid-payload", 150]
    mid = None
    _bi_gc_collect()
    total = 0
    count = 0
    cur = head
    while cur is not None:
        v = cur.val
        total = total + len(v[0]) + v[1] * 2
        count = count + 1
        cur = cur.nxt
    return total * 1000 + count


managed_entry()
