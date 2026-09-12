"""P5e batch 3: expandtabs, split/rsplit/splitlines, partition/rpartition.

Expected is computed by the host image builder from managed_entry().
"""


def managed_entry():
    n = 0
    if "a\tb".expandtabs(4) == "a   b":
        n = n + 1
    if "hello".expandtabs() == "hello":
        n = n + 2
    if "\ta".expandtabs() == "        a":
        n = n + 4
    if "hello".partition(",") == ("hello", "", ""):
        n = n + 8
    if "a,b,c".partition(",") == ("a", ",", "b,c"):
        n = n + 16
    if "a,b,c".rpartition(",") == ("a,b", ",", "c"):
        n = n + 32
    if "a b c".split() == ["a", "b", "c"]:
        n = n + 64
    if "  a  b".split() == ["a", "b"]:
        n = n + 128
    if "a,b,c".split(",") == ["a", "b", "c"]:
        n = n + 256
    if "".split() == []:
        n = n + 512
    if "".split(",") == [""]:
        n = n + 1024
    if "a,b,c,d".rsplit(",", 1) == ["a,b,c", "d"]:
        n = n + 2048
    if "a  b  c".split(None, 1) == ["a", "b  c"]:
        n = n + 4096
    if "a  b  c".rsplit(None, 1) == ["a  b", "c"]:
        n = n + 8192
    if "a\nb\n".splitlines() == ["a", "b"]:
        n = n + 16384
    if "a\nb".splitlines(True) == ["a\n", "b"]:
        n = n + 32768
    if "a\r\nb".splitlines() == ["a", "b"]:
        n = n + 65536
    if "a\r\nb".splitlines(True) == ["a\r\n", "b"]:
        n = n + 131072
    if "\n".splitlines() == [""]:
        n = n + 262144
    if "a,b,c,d".split(",", 2) == ["a", "b", "c,d"]:
        n = n + 524288
    if "a,b,".split(",") == ["a", "b", ""]:
        n = n + 1048576
    s = "abcdefghijklmnop"
    if s.split("x")[0] is s:
        n = n + 2097152
    if "abc".split(",") == ["abc"]:
        n = n + 4194304
    if "foo bar".rsplit(None, 1) == ["foo", "bar"]:
        n = n + 8388608
    return n


managed_entry()
