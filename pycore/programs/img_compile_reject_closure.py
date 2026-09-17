"""§11.4: nested load of an enclosing local compiles and runs.

compile()+exec of a nested function that reads an outer local returns 1.
"""

SRC = """\
def outer():
    x = 1
    def inner():
        return x
    return inner()
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    return ns["outer"]()


managed_entry()
