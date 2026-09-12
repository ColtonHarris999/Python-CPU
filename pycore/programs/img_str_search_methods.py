"""P5e batch 1: SEARCH methods via STRACC (find/rfind/count/index/replace).

join stays firmware until batch 4. Expected is computed by the host image
builder from managed_entry().
"""


def managed_entry():
    n = 0
    if "hello".find("ll") == 2:
        n = n + 1
    if "hello".find("z") == -1:
        n = n + 2
    if "banana".rfind("ana") == 3:
        n = n + 4
    if "banana".count("ana") == 1:
        n = n + 8
    if "hello".startswith("he"):
        n = n + 16
    if "hello".endswith("lo"):
        n = n + 32
    if "hello".index("ll") == 2:
        n = n + 64
    if "abc".replace("b", "X") == "aXc":
        n = n + 128
    if "banana".replace("ana", "XY") == "bXYna":
        n = n + 256
    s = "abcdefghijklmnop"
    if s.find("mn") == 12:
        n = n + 512
    if s.replace("a", "A")[0] == "A":
        n = n + 1024
    f = "hello".find
    if f("e") == 1:
        n = n + 2048
    if "abc".replace("", "-") == "-a-b-c-":
        n = n + 4096
    return n


managed_entry()
