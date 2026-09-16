"""A4: nlocals above the RF window cap is a compiler SyntaxError (J).

241 parameters exceed ``RF_WINDOW_CAP`` (240). ``compile()`` must raise
``SyntaxError`` rather than emit a frame the machine cannot execute.
"""


def managed_entry():
    src = "def f("
    i = 0
    while i < 241:
        if i != 0:
            src = src + ", "
        src = src + "x" + str(i)
        i = i + 1
    src = src + "):\n    return 0\n"
    try:
        compile(src, "<s>", "exec")
    except SyntaxError:
        return 1
    return 0


managed_entry()
