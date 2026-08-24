"""finally runs on normal fallthrough and before a pending exception reraises."""


def managed_entry():
    value = 0
    try:
        try:
            value = 1
            raise TypeError
        finally:
            value += 10
    except TypeError:
        value += 100

    try:
        value += 1000
    finally:
        value += 10000
    return value


managed_entry()
