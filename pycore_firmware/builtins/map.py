"""Apply ``function`` to items — returns a list.

Single-iterable form only (*iterables → CALL_FUNCTION_EX deferred).
Deviation: materializes results (no map iterator / YIELD).
"""


def map(function, iterable):
    out = []
    for x in iterable:
        out += [function(x)]
    return out
