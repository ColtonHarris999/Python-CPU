"""for i in range(len(s)): s[i] — the access pattern a tokenizer needs."""


def managed_entry():
    s = "abcabca"
    hits = 0
    for i in range(len(s)):
        if s[i] == "a":
            hits += 1
    return hits


managed_entry()
