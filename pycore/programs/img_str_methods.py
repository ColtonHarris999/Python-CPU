"""Native str methods: join, startswith, endswith, find.

Expected: 1+10+20+100+200 = 331.
"""


def managed_entry():
    n = 0
    if "-".join(["a", "b"]) == "a-b":
        n = n + 1
    if "hello".startswith("he"):
        n = n + 10
    if "hello".endswith("lo"):
        n = n + 20
    if "hello".find("ll") == 2:
        n = n + 100
    if "hello".find("z") == -1:
        n = n + 200
    return n


managed_entry()
