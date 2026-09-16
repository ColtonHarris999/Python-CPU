"""§11.4: nested load of an enclosing local is compile() SyntaxError.

OBJ_CLOSURE RTL (MAKE_CELL / LOAD_DEREF / cells) is not on this target;
D6 keeps closures a compile-time error rather than an illegal-opcode trap.
Returns 1 when compile() raises.
"""

SRC = """\
def outer():
    x = 1
    def inner():
        return x
    return inner
"""


def managed_entry():
    try:
        compile(SRC, "<s>", "exec")
    except SyntaxError:
        return 1
    return 0


managed_entry()
