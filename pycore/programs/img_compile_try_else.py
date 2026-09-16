"""T4: compile() try/except/else (compiler_design.md §11.2)."""

SRC = """\
try:
    x = 1
except TypeError:
    x = 2
else:
    x = 3
"""

x = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return x


managed_entry()
