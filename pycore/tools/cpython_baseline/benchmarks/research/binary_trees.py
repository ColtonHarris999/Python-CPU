# Computer Language Benchmarks Game, binary-trees.
# The published Python builds a Tree class and prints a check per depth.
# A node here is a two-element list and a leaf is the int 0, so there is no
# class. The check is the same: 1 + check(left) + check(right), and a leaf is 1.
# Official arguments go to 21. N=8 keeps the allocation inside Callgrind.
# The printed integer is stretch + long-lived + the sum of the per-depth checks.

N = 8
MIN_DEPTH = 4


def make(depth):
    if depth == 0:
        return 0
    return [make(depth - 1), make(depth - 1)]


def check(node):
    if node == 0:
        return 1
    return 1 + check(node[0]) + check(node[1])


def binary_trees(n):
    if n > MIN_DEPTH + 2:
        max_depth = n
    else:
        max_depth = MIN_DEPTH + 2
    total = check(make(max_depth + 1))
    long_lived = make(max_depth)
    depth = MIN_DEPTH
    while depth <= max_depth:
        iterations = 1 << (max_depth - depth + MIN_DEPTH)
        acc = 0
        i = 0
        while i < iterations:
            acc = acc + check(make(depth))
            i = i + 1
        total = total + acc
        depth = depth + 2
    total = total + check(long_lived)
    return total


if __name__ == "__main__":
    print(binary_trees(N))
