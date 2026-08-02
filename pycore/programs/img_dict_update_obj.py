"""Contaminated DICT_UPDATE via `{**a, **b}` with OBJECT (instance) keys.

Instance keys tag as OBJECT, so both source dicts carry the contamination bit
and the excore DICT_UPDATE fast path is skipped — pycore owns the whole update
(grow + rehash + order-copy + insert/overwrite). The second update grows the
4-slot accumulator past its 2/3 load factor (rehash to a larger table), and key
``p`` appears in both operands so the duplicate-overwrite path runs too. len(d)
counts the four surviving unique keys.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_INSTANCE o type=T slots=0
# pycore-inject: SEED_INSTANCE p type=T slots=0
# pycore-inject: SEED_INSTANCE q type=T slots=0
# pycore-inject: SEED_INSTANCE r type=T slots=0
"""


def managed_entry():
    a = {o: 1, p: 2}
    b = {p: 5, q: 3, r: 4}
    d = {**a, **b}
    # len counts the four unique keys; d[p] confirms b overwrote a (5, not 2);
    # d[o]/d[q]/d[r] confirm the rehashed + freshly inserted values survive.
    return len(d) * 10000 + d[o] * 1000 + d[p] * 100 + d[q] * 10 + d[r]


managed_entry()
