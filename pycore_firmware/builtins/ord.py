"""Unicode code point of a one-character string.

Blocked: character iteration yields SHORT_STR, but there is no pure-Python
way to read the payload bytes as an integer (no byte access primitive).
"""


def ord(c):
    return 1 % 0
