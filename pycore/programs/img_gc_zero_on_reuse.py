"""GC: memory reused from a free run reads as zero (gc_plan.md §4.7).

Dict and set tables rely on zero-filled memory for empty slots. Tables of
the same sizes are built, dropped, and collected, then rebuilt with
overlapping keys into the reclaimed runs: a table slot left stale from the
dropped generation would make an insert look like a duplicate (or a lookup
hit a key that was never inserted), and the counts below would drift.
"""


def fill(base):
    s = {base, base + 1, base + 2, base + 3, base + 4, base + 5}
    d = {base: 1, base + 1: 2, base + 2: 3, base + 3: 4, base + 4: 5}
    return [s, d]


def score(pair, base):
    s, d = pair
    hits = 0
    for k in (base - 3, base - 2, base - 1, base, base + 5, base + 6):
        if k in s:
            hits += 1
        if k in d:
            hits += 10
    return len(s) * 1000 + len(d) * 100 + hits


def managed_entry():
    old = [fill(0), fill(0), fill(0), fill(0)]
    old = None
    _bi_gc_collect()
    total = 0
    for i in range(4):
        total = total * 10 + score(fill(3), 3) % 10
        total += score(fill(3), 3)
    return total


managed_entry()
