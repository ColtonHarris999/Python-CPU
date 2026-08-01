"""Return a frozenset.

PY_TAG_FROZENSET is reserved / unimplemented in pycore. Cannot allocate
an immutable set distinct from MUT_SET. See builtins.md.
"""


def frozenset(iterable=None):
    # Blocked — no frozenset object layout yet.
    return 1 % 0
