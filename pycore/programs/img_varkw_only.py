"""CO_VARKEYWORDS only: all keywords go into the dict."""


def f(**k):
    return k["x"] + 10 * k["y"]


def managed_entry():
    return f(x=3, y=4)


managed_entry()
