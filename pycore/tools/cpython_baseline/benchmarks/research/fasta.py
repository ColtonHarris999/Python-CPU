# Computer Language Benchmarks Game, fasta.
# The published program writes three FASTA records: a repeated ALU sequence,
# random IUB ambiguity codes, and random Homo sapiens bases. The generator is
# the benchmark's own LCG, not the random module:
#     seed = (seed * 3877 + 29573) % 139968
# Official lengths are ALU 2*n, IUB 3*n, Homo sapiens 5*n with n=1000 and up.
# N=1000 is that minimum. Bases are not stored (no file, no str.join). The
# checksum is the sum of ord of every emitted base. The random seed carries
# from the IUB record into the Homo sapiens record.

N = 1000

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

# Published Homo sapiens base frequencies. They sum to 1.
HOMO = [
    ["a", 0.3029549426680],
    ["c", 0.1979883004921],
    ["g", 0.1975473066391],
    ["t", 0.3015094502008],
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


def repeat_alu(length, acc):
    alu_n = len(ALU)
    i = 0
    while i < length:
        acc = acc + ord(ALU[i % alu_n])
        i = i + 1
    return acc


def random_bases(table, length, seed, acc):
    chars, probs = cumulative(table)
    i = 0
    while i < length:
        seed = (seed * IA + IC) % IM
        base = pick(chars, probs, seed / IM)
        acc = acc + ord(base)
        i = i + 1
    return seed, acc


def fasta(n):
    acc = repeat_alu(n * 2, 0)
    seed, acc = random_bases(IUB, n * 3, 42, acc)
    seed, acc = random_bases(HOMO, n * 5, seed, acc)
    return acc


if __name__ == "__main__":
    print(fasta(N))
