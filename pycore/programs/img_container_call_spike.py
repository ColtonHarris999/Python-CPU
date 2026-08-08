def make_items():
    a = 1
    b = 2
    c = 3
    return [a, b, c]


def __iter__():
    return make_items()


def managed_entry():
    return len(__iter__())


managed_entry()
