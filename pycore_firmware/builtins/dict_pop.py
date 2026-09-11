"""dict.pop — native method table entry 14.

``d.pop(k)`` raises KeyError on miss; ``d.pop(k, default)`` returns default.
"""


def dict_pop(self, key, *args):
    if key in self:
        value = self[key]
        del self[key]
        return value
    if len(args) == 0:
        raise KeyError
    return args[0]
