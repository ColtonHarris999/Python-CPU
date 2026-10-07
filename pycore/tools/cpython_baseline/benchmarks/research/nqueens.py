# pyperformance bm_nqueens. Brute-force N-queens, Collin Winter.
# The published solver checks every permutation (itertools.permutations).
# This is Heap's algorithm, which visits the same set once each, and counts
# solutions instead of yielding them. Official queen_count is 8 (92 solutions).
# N=7 (40 solutions) keeps the Callgrind run bounded.
# A solution is a permutation whose (col+row) and (col-row) diagonals are unique.

N = 7


def attacks(perm, n):
    diag1 = []
    diag2 = []
    i = 0
    while i < n:
        diag1.append(perm[i] + i)
        diag2.append(perm[i] - i)
        i = i + 1
    return len(set(diag1)) != n or len(set(diag2)) != n


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
