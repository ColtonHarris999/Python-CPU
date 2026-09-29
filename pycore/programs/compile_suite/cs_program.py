# Compile suite: a larger ordinary program. Its compile needs well over the
# ~600 KB of heap the 2 MB data window left free, so it only compiles on
# the 16 MB map.
def sieve(limit):
    flags = [1] * (limit + 1)
    flags[0] = 0
    flags[1] = 0
    p = 2
    while p * p <= limit:
        if flags[p]:
            m = p * p
            while m <= limit:
                flags[m] = 0
                m += p
        p += 1
    return [i for i in range(limit + 1) if flags[i]]


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def insertion_sort(xs):
    out = []
    for v in xs:
        i = len(out)
        out.append(v)
        while i > 0 and out[i - 1] > v:
            out[i] = out[i - 1]
            i -= 1
        out[i] = v
    return out


def word_counts(text):
    counts = {}
    word = ""
    for ch in text + " ":
        if ch == " ":
            if word:
                counts[word] = counts.get(word, 0) + 1
            word = ""
        else:
            word = word + ch
    return counts


def matmul(a, b):
    n = len(a)
    m = len(b[0])
    k = len(b)
    out = []
    for i in range(n):
        row = []
        for j in range(m):
            s = 0
            for t in range(k):
                s += a[i][t] * b[t][j]
            row.append(s)
        out.append(row)
    return out


def collatz_len(n):
    steps = 0
    while n != 1:
        n = n // 2 if n % 2 == 0 else 3 * n + 1
        steps += 1
    return steps


class_like = {"name": "stack", "items": []}


def push(obj, v):
    obj["items"].append(v)
    return len(obj["items"])


def pop(obj):
    return obj["items"].pop()


primes = sieve(60)
print("primes", len(primes), primes[-1])
print("gcd", gcd(84, 36), gcd(17, 5))
ordered = insertion_sort([5, 2, 9, 1, 7, 3])
print("sort", ordered[0], ordered[3], ordered[-1])
wc = word_counts("a b a c b a")
print("words", wc["a"], wc["b"], len(wc))
prod = matmul([[1, 2], [3, 4]], [[5, 6], [7, 8]])
print("matmul", prod[0][0], prod[1][1])
best = 0
arg = 0
for n in range(1, 30):
    c = collatz_len(n)
    if c > best:
        best = c
        arg = n
print("collatz", arg, best)
push(class_like, 1)
push(class_like, 2)
print("stack", push(class_like, 3), pop(class_like), len(class_like["items"]))
