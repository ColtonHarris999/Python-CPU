"""An empty DICT exhausts immediately. Expected result: 7."""


def managed_entry():
    result = 7
    for key in {}:
        result += key
    return result


managed_entry()
