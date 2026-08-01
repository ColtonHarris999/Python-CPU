"""Create a set, optionally from an iterable.

Empty set: ``{*()}`` → BUILD_SET + SET_UPDATE (excore).
From iterable: ``{*iterable}`` → SET_UPDATE (LIST/TUPLE/SET sources).
Native BI_SET remains the on-core fast path.
"""


def set(iterable=None):
    if iterable is None:
        return {*()}
    return {*iterable}
