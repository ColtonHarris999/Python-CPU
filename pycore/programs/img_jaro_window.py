"""strsimpy JaroWinkler.matches window + match count.

Lifts the TYPE trap on ``int(max(len(s) / 2 - 1, 0))`` (true-div FLOAT,
then max(FLOAT, INT), then int(FLOAT)). Mirrors
https://github.com/luozhouyang/python-string-similarity
``strsimpy/jaro_winkler.py`` ``matches`` without the later transposition
walk.

Host golden: ran("ab","ac")=0 + ran("martha","marhta")=2 + matches("ab","ac")=1
→ 201
"""


def _window(s0, s1):
    if len(s0) > len(s1):
        max_str = s0
        min_str = s1
    else:
        max_str = s1
        min_str = s0
    return int(max(len(max_str) / 2 - 1, 0))


def _matches(s0, s1):
    if len(s0) > len(s1):
        max_str = s0
        min_str = s1
    else:
        max_str = s1
        min_str = s0
    ran = int(max(len(max_str) / 2 - 1, 0))
    match_flags = [False] * len(max_str)
    matches = 0
    for mi in range(len(min_str)):
        c1 = min_str[mi]
        start = max(mi - ran, 0)
        stop = min(mi + ran + 1, len(max_str))
        for xi in range(start, stop):
            if not match_flags[xi] and c1 == max_str[xi]:
                match_flags[xi] = True
                matches += 1
                break
    return matches


def managed_entry():
    total = 0
    total += _window("ab", "ac") * 100
    total += _window("martha", "marhta") * 100
    total += _matches("ab", "ac")
    return total


managed_entry()
