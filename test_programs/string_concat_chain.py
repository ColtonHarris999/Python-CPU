# Tests chained short-string concatenations.
def managed_entry() -> str:
    a = "foo"
    b = "bar"
    c = "baz"
    ab = a + b     # "foobar"
    return ab + c  # "foobarbaz" — 9 bytes, SHORT_STR
