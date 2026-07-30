"""DICT iteration yields keys in insertion order. Expected result: 13."""


def managed_entry():
    d = {}
    d[1] = 2
    d[3] = 4
    result = 0
    for key in d:
        result = result * 10 + key
    return result


managed_entry()
