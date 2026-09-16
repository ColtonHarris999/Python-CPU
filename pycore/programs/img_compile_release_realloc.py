"""R7: compile, release, compile again; the second result is correct.

Caller mark/release must recycle heap and code RAM so a second ``compile()``
cannot observe a stale CODC/GIC alias. Host CPython has no bump cursor, so
the packed golden is stated directly.

# pycore-expect: 37
"""


def managed_entry():
    hm = _bi_heap_mark()
    cm = _bi_code_mark()
    c1 = compile("1 + 2", "<s>", "eval")
    v1 = eval(c1)
    _bi_code_release(cm)
    _bi_heap_release(hm)
    c2 = compile("3 + 4", "<s>", "eval")
    v2 = eval(c2)
    return v1 * 10 + v2


managed_entry()
