# Computer Language Benchmarks Game, fasta.
# The published program writes three FASTA records: a repeated ALU sequence,
# random IUB ambiguity codes, and random Homo sapiens bases. The generator is
# the benchmark's own LCG, not the random module:
#     seed = (seed * 3877 + 29573) % 139968
# Official lengths are ALU 2*n, IUB 3*n, Homo sapiens 5*n with n=1000 and up.
# This run uses a fixed short ALU and N random IUB bases. Bases stay in a list
# of one-character strings (no file, no str.join). The checksum is the sum of
# ord of every emitted base, which does not depend on dict order.

N = 5000

ALU = (
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG"
    "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
    "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT"
    "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
    "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG"
    "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
    "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"
)

# Cumulative tables are built from these frequencies. They sum to 1.
IUB = [
    ["a", 0.27],
    ["c", 0.12],
    ["g", 0.12],
    ["t", 0.27],
    ["B", 0.02],
    ["D", 0.02],
    ["H", 0.02],
    ["K", 0.02],
    ["M", 0.02],
    ["N", 0.02],
    ["R", 0.02],
    ["S", 0.02],
    ["V", 0.02],
    ["W", 0.02],
    ["Y", 0.02],
]

IM = 139968
IA = 3877
IC = 29573


def cumulative(table):
    chars = []
    probs = []
    acc = 0.0
    i = 0
    while i < len(table):
        acc = acc + table[i][1]
        chars.append(table[i][0])
        probs.append(acc)
        i = i + 1
    return chars, probs


def pick(chars, probs, rnd):
    i = 0
    last = len(probs) - 1
    while i < last:
        if rnd < probs[i]:
            return chars[i]
        i = i + 1
    return chars[last]


def fasta(n):
    acc = 0
    alu_n = len(ALU)
    i = 0
    while i < alu_n:
        acc = acc + ord(ALU[i])
        i = i + 1
    chars, probs = cumulative(IUB)
    seed = 42
    i = 0
    while i < n:
        seed = (seed * IA + IC) % IM
        base = pick(chars, probs, seed / IM)
        acc = acc + ord(base)
        i = i + 1
    return acc


if __name__ == "__main__":
    print(fasta(N))
