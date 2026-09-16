"""T4: compile() list comprehension (compiler_design.md §11.2).

LIST_APPEND of an empty BUILD_LIST hits the grow path, so this image runs
on the two-core top.
"""

SRC = """\
xs = [x for x in [1, 2, 3, 4, 5]]
s = 0
for v in xs:
    s = s + v
"""

xs = None
s = None
x = None
v = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return s


managed_entry()
