"""CALL_FUNCTION_EX with DICT_MERGE empty-dest **kwargs path."""


def h(a, b=0):
    return a + 10 * b


def managed_entry():
    return h(*(1,), **{"b": 2}) + h(*[], **{"a": 5, "b": 3})


managed_entry()
