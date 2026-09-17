"""T5: identity decorator around a def that returns 7."""

SRC = """\
def d(fn):
    return fn
@d
def f():
    return 7
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    return ns["f"]()


managed_entry()
