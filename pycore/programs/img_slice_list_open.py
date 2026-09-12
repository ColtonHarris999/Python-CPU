"""Open LIST/TUPLE slices: omitted bounds arrive as None."""


def managed_entry():
    one = 1
    two = 2
    three = 3
    xs = [one, two, three]
    prefix = xs[:two]
    suffix = xs[one:]
    whole = xs[:]
    t = (one, two, three)
    t_suf = t[one:]
    total = prefix[0] + 10 * prefix[1]
    total += 100 * suffix[0] + 1000 * suffix[1]
    total += 10000 * len(whole)
    total += t_suf[0]
    return total


managed_entry()
