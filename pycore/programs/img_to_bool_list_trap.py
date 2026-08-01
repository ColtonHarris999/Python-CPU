"""Legacy name: nonempty list is now truthy (was TYPE trap)."""


def managed_entry():
    lst = [1]
    if lst:
        return 1
    return 0


managed_entry()
