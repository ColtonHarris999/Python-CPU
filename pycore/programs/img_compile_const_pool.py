"""Def then non-small-int consts plus empty if must compile (no TYPE trap)."""

SRC = """\
def f():
    return 1
x = "hello"
y = 1000
z = 1000.0
if y:
    pass
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    if ns["f"]() == 1:
        if ns["x"] == "hello":
            if ns["y"] == 1000:
                return 7
    return 0


managed_entry()
