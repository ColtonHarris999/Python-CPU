def make(n, seed):
    rows = []
    i = 0
    while i < n:
        row = []
        j = 0
        while j < n:
            seed = (seed * 1103515245 + 12345) & 255
            row.append(seed)
            j = j + 1
        rows.append(row)
        i = i + 1
    return rows


def mul(a, b, n):
    out = []
    i = 0
    while i < n:
        row = []
        j = 0
        while j < n:
            acc = 0
            k = 0
            while k < n:
                acc = acc + a[i][k] * b[k][j]
                k = k + 1
            row.append(acc)
            j = j + 1
        out.append(row)
        i = i + 1
    return out


def managed_entry():
    n = 6
    a = make(n, 7)
    b = make(n, 99)
    c = mul(a, b, n)
    return c[0][0] + c[5][5]


managed_entry()
