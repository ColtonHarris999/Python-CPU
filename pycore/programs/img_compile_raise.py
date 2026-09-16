"""T4: compile() raise TypeError is caught (compiler_design.md §11.2)."""

SRC = """\
try:
    raise TypeError
except TypeError as e:
    x = 7
"""

x = None
e = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return x


managed_entry()
