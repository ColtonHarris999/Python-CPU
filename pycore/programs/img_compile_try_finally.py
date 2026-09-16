"""T4: compile() try/finally (compiler_design.md §11.2)."""

SRC = """\
x = 1
try:
    x = x + 1
finally:
    x = x + 10
"""

x = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return x


managed_entry()
