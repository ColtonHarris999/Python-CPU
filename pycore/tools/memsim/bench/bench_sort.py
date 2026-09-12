def isort(a):
    n = len(a)
    i = 1
    while i < n:
        j = i
        while j > 0:
            x = a[j]
            y = a[j - 1]
            if y <= x:
                break
            a[j] = y
            a[j - 1] = x
            j = j - 1
        i = i + 1
    return a


def managed_entry():
    data = []
    seed = 12345
    k = 0
    while k < 48:
        seed = (seed * 1103515245 + 12345) & 65535
        data.append(seed)
        k = k + 1
    out = isort(data)
    return out[0] + out[47]


managed_entry()
