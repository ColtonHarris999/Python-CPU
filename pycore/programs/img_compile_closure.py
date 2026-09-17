"""§11.4: closure captures a parameter and a later STORE_DEREF.

``outer(3)`` builds ``inner`` that reads ``x``; ``x = x + 4`` before the
call so the cell holds 7.
"""

SRC = """\
def outer(x):
    def inner():
        return x
    x = x + 4
    return inner()
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    return ns["outer"](3)


managed_entry()
