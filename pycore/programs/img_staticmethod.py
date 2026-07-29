"""M4: @staticmethod does not bind self (CALL with NULL sentinel)."""


class Util:
    @staticmethod
    def add(a, b):
        return a + b


def managed_entry():
    # Instance attribute load of staticmethod → [func, NULL] + CALL 2
    u = Util()
    return u.add(3, 4)


managed_entry()
