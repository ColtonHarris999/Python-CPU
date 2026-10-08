"""Print objects to the console.

``_bi_print`` writes a primitive (str, int, bool, None) straight to the
console and returns None. ``_bi_write`` stores a string. Containers and
objects go through ``str`` once that dispatch exists; until then a
non-primitive ``_bi_print`` is a type trap, matching the previous sink.
"""


def print(*args, sep=" ", end="\n"):
    if sep is None:
        sep = " "
    if end is None:
        end = "\n"
    n = len(args)
    i = 0
    while i < n:
        if i > 0:
            _bi_write(sep)
        _bi_print(args[i])
        i = i + 1
    _bi_write(end)
    return None
