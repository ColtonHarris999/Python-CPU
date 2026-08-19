"""ord() + s[i]: the character-classification loop a tokenizer needs.

This is the pattern P0 of the compile()/exec() plan exists to enable — index a
source string, classify each character by code-point range, no dict probes.
"""


def managed_entry():
    src = "a1b22c"
    digits = 0
    letters = 0
    for i in range(len(src)):
        cp = ord(src[i])
        if cp >= 48:
            if cp <= 57:
                digits += 1
        if cp >= 97:
            if cp <= 122:
                letters += 1
    return digits * 10 + letters


managed_entry()
