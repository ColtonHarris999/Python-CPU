"""dict.get — native method table entry 10."""


def dict_get(self, key, default=None):
    if key in self:
        return self[key]
    return default
