"""Executed from code RAM instead of ROM (Plan 1 P1).

Run twice by the Makefile: once as an ordinary ROM image and once with
--code-ram, which offsets every entry slot into the writable region and loads it
through CODE_RAM_HEX with an empty ROM. Both runs must produce the same value,
which is what proves the fetch region mux is transparent.

Exercises calls, a nested call, a backward branch and a builtin so the check
covers redirects and not just straight-line fetch.
"""


def helper(x):
    return x * 3


def outer(x):
    return helper(x) + 1


def managed_entry():
    total = 0
    i = 0
    while i < 4:
        total += outer(i)
        i += 1
    s = "abcd"
    total += len(s)
    total += ord(s[2])
    return total


managed_entry()
