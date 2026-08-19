"""Each seeded exception type is distinguishable by an exact-match handler.

Also checks that a non-matching arm does not swallow the wrong type: the
ValueError raise is caught by the ValueError arm, not by the TypeError one that
precedes it.

Raises are in the same frame as their handler: an exception raised in a callee
does not propagate to a caller's handler (see img_try_exc_cross_frame_fatal).
"""


def managed_entry():
    total = 0
    try:
        raise ValueError
    except TypeError:
        total += 1000
    except ValueError:
        total += 1
    try:
        raise TypeError
    except ValueError:
        total += 2000
    except TypeError:
        total += 10
    try:
        raise IndexError
    except IndexError:
        total += 100
    try:
        raise SyntaxError
    except SyntaxError:
        total += 1000
    return total


managed_entry()
