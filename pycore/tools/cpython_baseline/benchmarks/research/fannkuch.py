# pyperformance bm_fannkuch, from the Computer Language Benchmarks Game.
# Sokolov Yura, modified by Tupteq.
#
# Official argument is 9 (max flips 30). N=7 (max flips 16) is the largest
# argument whose permutation walk finishes under Callgrind in about a minute.
# The permutation walk is the published one.
# The pancake reverse is an index swap instead of perm[k::-1], which needs a
# slice step. The rotate is an index move instead of list.insert / list.pop.

N = 7


def fannkuch(n):
    count = []
    perm1 = []
    i = 0
    while i < n:
        count.append(i + 1)
        perm1.append(i)
        i = i + 1
    max_flips = 0
    m = n - 1
    r = n
    while 1:
        while r != 1:
            count[r - 1] = r
            r = r - 1
        if perm1[0] != 0 and perm1[m] != m:
            perm = []
            i = 0
            while i < n:
                perm.append(perm1[i])
                i = i + 1
            flips = 0
            k = perm[0]
            while k:
                a = 0
                b = k
                while a < b:
                    tmp = perm[a]
                    perm[a] = perm[b]
                    perm[b] = tmp
                    a = a + 1
                    b = b - 1
                flips = flips + 1
                k = perm[0]
            if flips > max_flips:
                max_flips = flips
        while r != n:
            first = perm1[0]
            i = 0
            while i < r:
                perm1[i] = perm1[i + 1]
                i = i + 1
            perm1[r] = first
            count[r] = count[r] - 1
            if count[r] > 0:
                break
            r = r + 1
        else:
            return max_flips


if __name__ == "__main__":
    print(fannkuch(N))
