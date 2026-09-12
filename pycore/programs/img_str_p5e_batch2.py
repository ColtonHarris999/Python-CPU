"""P5e batch 2+: JOIN, TRIM, CLASSIFY, MAP, PAD, AFFIX, ZFILL via STRACC.

Expected is computed by the host image builder from managed_entry().
"""


def managed_entry():
    n = 0
    a = "a"
    b = "b"
    if "-".join([a, b]) == "a-b":
        n = n + 1
    if "  hi  ".strip() == "hi":
        n = n + 2
    if "  hi  ".lstrip() == "hi  ":
        n = n + 4
    if "  hi  ".rstrip() == "  hi":
        n = n + 8
    if "Ab".upper() == "AB":
        n = n + 16
    if "Ab".lower() == "ab":
        n = n + 32
    if "Ab".swapcase() == "aB":
        n = n + 64
    if "12".isdigit():
        n = n + 128
    if "hi".isascii():
        n = n + 256
    if "abc".islower():
        n = n + 512
    if "ABC".isupper():
        n = n + 1024
    if "hi".center(6) == "  hi  ":
        n = n + 2048
    if "hi".ljust(4) == "hi  ":
        n = n + 4096
    if "hi".rjust(4) == "  hi":
        n = n + 8192
    if "foobar".removeprefix("foo") == "bar":
        n = n + 16384
    if "foobar".removesuffix("bar") == "foo":
        n = n + 32768
    if "42".zfill(5) == "00042":
        n = n + 65536
    if "-42".zfill(5) == "-0042":
        n = n + 131072
    if "hello".capitalize() == "Hello":
        n = n + 262144
    if "hello world".title() == "Hello World":
        n = n + 524288
    if "ß".casefold() == "ss":
        n = n + 1048576
    if "Hello".istitle():
        n = n + 2097152
    if "12".isdecimal():
        n = n + 4194304
    if "½".isnumeric():
        n = n + 8388608
    if "ab".isprintable():
        n = n + 16777216
    if "xxhiyy".strip("xy") == "hi":
        n = n + 33554432
    if "".join(["x"]) == "x":
        n = n + 67108864
    if "-".join("ab") == "a-b":
        n = n + 134217728
    return n


managed_entry()
