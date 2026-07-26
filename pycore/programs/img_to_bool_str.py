# Exercises TO_BOOL across SHORT_STR and LONG_STR values.
#
# Empty SHORT_STR skips +100, non-empty SHORT_STR takes +1, and the >15-byte
# literal is encoded as LONG_STR and takes +10. The host golden is 11.


def managed_entry():
    empty = ""
    short = "hi"
    long = "this is a long string!!"
    out = 0
    if empty:
        out += 100
    if short:
        out += 1
    if long:
        out += 10
    return out


managed_entry()
