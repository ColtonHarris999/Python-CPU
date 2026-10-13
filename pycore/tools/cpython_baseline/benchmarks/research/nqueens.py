# pyperformance bm_nqueens. Brute-force N-queens, Collin Winter.
# The published solver checks every permutation (itertools.permutations).
# This is Heap's algorithm, which visits the same set once each, and counts
# solutions instead of yielding them. N is the official queen_count, 8
# (92 solutions).
# A solution is a permutation whose (col+row) and (col-row) diagonals are unique.

N = 8


def attacks(perm, n):
    # Two queens share a diagonal when the column distance equals the row
    # distance. That is the same test as a set of (col + row) and
    # (col - row). The sets would stay live for all 8! permutations,
    # which exhausts the heap while the collector is off.
    i = 0
    while i < n:
        j = i + 1
        while j < n:
            d = perm[i] - perm[j]
            if d < 0:
                d = -d
            if d == (j - i):
                return 1
            j = j + 1
        i = i + 1
    return 0


def nqueens(n):
    perm = []
    c = []
    i = 0
    while i < n:
        perm.append(i)
        c.append(0)
        i = i + 1
    count = 0
    if not attacks(perm, n):
        count = count + 1
    i = 0
    while i < n:
        if c[i] < i:
            if i % 2 == 0:
                swap = 0
            else:
                swap = c[i]
            tmp = perm[swap]
            perm[swap] = perm[i]
            perm[i] = tmp
            if not attacks(perm, n):
                count = count + 1
            c[i] = c[i] + 1
            i = 0
        else:
            c[i] = 0
            i = i + 1
    return count


if __name__ == "__main__":
    print(nqueens(N))
