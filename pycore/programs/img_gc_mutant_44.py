"""G10 mutant 44: the idle-cleanup skip must notice a compile().

compile() writes `_PYC_G["_busy"]`, which marks the compiler arena dirty.
The next idle collection must clear the scratch slots before it premarks
`_PYC_G`; skipping that loop would leave the finished compile's arrays
reachable only through a dictionary the collector no longer traces, and
the oracle would see reachable granules freed.
"""


def managed_entry():
    total = 0
    for i in range(3):
        co = compile("40 + 2", "<gc-m44>", "eval")
        _bi_gc_collect()
        total = total + eval(co)
    return total


managed_entry()
