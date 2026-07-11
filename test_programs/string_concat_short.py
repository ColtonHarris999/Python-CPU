# Tests short-string concatenation (result fits in the 15-byte SHORT_STR payload).
def managed_entry() -> str:
    a = "Hello"
    b = " CPU"
    return a + b   # "Hello CPU" — 9 bytes, fits in SHORT_STR
