"""CO_VARARGS + two kw-only args; regresses CALL binder idx after *args pack."""


def f(*a, x=1, y=2):
    return len(a) * 1000 + x * 100 + y


def managed_entry():
    # Two positionals into *a leaves pack idx at 1; KW bind must still see x=.
    return f(7, 8, x=3, y=4)


managed_entry()
