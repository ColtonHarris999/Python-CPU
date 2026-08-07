"""More than two positionals (proves not limited by trap mailbox arity)."""


def managed_entry():
    print(1, 2, 3, 4, 5)
    return 0


managed_entry()
