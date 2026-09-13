"""Set-associative write-back cache model + the PyCore-specific structures."""
from __future__ import annotations

from dataclasses import dataclass, field


class Cache:
    def __init__(self, size_bytes: int, line_bytes: int, ways: int, name="L1"):
        self.line = line_bytes
        self.ways = ways
        self.sets = max(1, size_bytes // (line_bytes * ways))
        self.tags: list[list[int]] = [[] for _ in range(self.sets)]  # MRU-last LRU
        self.name = name
        self.hits = 0
        self.misses = 0

    def access(self, addr: int) -> bool:
        line = addr // self.line
        s = line % self.sets
        way = self.tags[s]
        if line in way:
            way.remove(line)
            way.append(line)
            self.hits += 1
            return True
        self.misses += 1
        way.append(line)
        if len(way) > self.ways:
            way.pop(0)
        return False

    @property
    def total(self):
        return self.hits + self.misses

    @property
    def hit_rate(self):
        return self.hits / self.total if self.total else 0.0


class TwoLevel:
    """L1 backed by a shared L2; an L1 miss probes L2."""

    def __init__(self, l1: Cache, l2: Cache):
        self.l1, self.l2 = l1, l2

    def access(self, addr: int) -> str:
        if self.l1.access(addr):
            return "l1"
        return "l2" if self.l2.access(addr) else "mem"


def gic_set_index(key) -> int:
    """RTL GIC (`pycore_gic.sv`): set index is namei LSBs, not Python `hash`.

    Key is `(code_id_or_addr, namei)`. 16 entries / 2-way → 8 sets, so the
    hardware uses `key[2:0] == namei[2:0]`.
    """
    return int(key[1]) & 0x7


def codc_set_index(addr) -> int:
    """RTL CODC (`pycore_codc.sv`): set index is `(addr >> 6)` (line number)."""
    return int(addr) >> 6


@dataclass
class DirectTagCache:
    """A tagged lookaside keyed by an arbitrary python-level key (not an address).

    Models the Python-aware structures: a per-frame const cache keyed by
    (code, const index), a global-name inline cache keyed by (code, namei), a
    code-object descriptor cache keyed by code address.

    `index_fn`, when set, must be deterministic. Python's salted `hash()` is
    not a model of the RTL — GIC uses namei LSBs, CODC uses `(addr >> 6)`.
    """
    entries: int
    ways: int = 1
    name: str = "struct"
    index_fn: object = None
    _sets: dict = field(default_factory=dict)
    hits: int = 0
    misses: int = 0
    invalidations: int = 0

    def __post_init__(self):
        self.nsets = max(1, self.entries // self.ways)

    def access(self, key) -> bool:
        if callable(self.index_fn):
            s = int(self.index_fn(key)) % self.nsets
        else:
            s = hash(key) % self.nsets
        way = self._sets.setdefault(s, [])
        if key in way:
            way.remove(key)
            way.append(key)
            self.hits += 1
            return True
        self.misses += 1
        way.append(key)
        if len(way) > self.ways:
            way.pop(0)
        return False

    def flush(self):
        self._sets.clear()
        self.invalidations += 1

    @property
    def total(self):
        return self.hits + self.misses

    @property
    def hit_rate(self):
        return self.hits / self.total if self.total else 0.0
