"""Sum start and the items of an iterable."""


def sum(iterable, start=0):
    total = start
    for x in iterable:
        total = total + x
    return total
