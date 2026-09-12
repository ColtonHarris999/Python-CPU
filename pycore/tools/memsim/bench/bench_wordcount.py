def tally(text):
    counts = {}
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch in counts:
            counts[ch] = counts[ch] + 1
        else:
            counts[ch] = 1
        i = i + 1
    return counts


def managed_entry():
    text = "the quick brown fox jumps over the lazy dog again and again"
    counts = tally(text)
    total = 0
    for k in counts:
        total = total + counts[k]
    return total


managed_entry()
