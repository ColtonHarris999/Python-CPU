"""print kwargs: sep= and end= via CALL_KW."""


def managed_entry():
    print(1, 2, sep=",", end=";")
    print(3, end="")
    print()
    return 0


managed_entry()
