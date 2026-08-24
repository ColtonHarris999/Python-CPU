"""try/except/else: fall through to else only when no exception is raised."""


def choose(should_raise):
    value = 0
    try:
        if should_raise:
            raise TypeError
    except TypeError:
        value += 10
    else:
        value += 1
    return value


def managed_entry():
    return choose(False) + choose(True)


managed_entry()
