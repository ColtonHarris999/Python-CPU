"""jaro.similarity match-flag shape: ``[False] * len(s)`` then index/store.

Mirrors the first TYPE ceiling in cjkfuzz ``jaro.similarity`` without the
later float/division work.
"""


def managed_entry():
    s1 = "ab"
    s2 = "ac"
    s1_len = len(s1)
    s2_len = len(s2)
    s1_matches = [False] * s1_len
    s2_matches = [False] * s2_len
    matches = 0
    for i in range(s1_len):
        for j in range(s2_len):
            if s2_matches[j]:
                continue
            if s1[i] != s2[j]:
                continue
            s1_matches[i] = True
            s2_matches[j] = True
            matches += 1
            break
    total = matches * 100
    if s1_matches[0]:
        total += 1
    if not s1_matches[1]:
        total += 10
    if s2_matches[0]:
        total += 20
    if not s2_matches[1]:
        total += 3
    return total


managed_entry()
