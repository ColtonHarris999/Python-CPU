# Computer Language Benchmarks Game, k-nucleotide.
# The published program counts 1- and 2-nucleotide frequencies, then looks up
# a few longer frames, in a DNA sequence read from a FASTA record. The hot
# work is the dict. This run repeats the fasta ALU to length N and counts
# frames of length 1 and 2. Keys are one- and two-character strings.
# The checksum is order-independent: each count is weighted by the codes of
# its key, so a wrong bucket changes the total. Official inputs are tens of
# megabytes. N is a few thousand bases so Callgrind finishes.

N = 8000

ALU = (
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG"
    "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
    "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT"
    "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
    "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG"
    "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
    "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"
)


def sequence(n):
    seq = []
    alu_n = len(ALU)
    i = 0
    while i < n:
        seq.append(ALU[i % alu_n])
        i = i + 1
    return seq


def count_frame(seq, k):
    counts = {}
    last = len(seq) - k + 1
    i = 0
    while i < last:
        if k == 1:
            key = seq[i]
        else:
            key = seq[i] + seq[i + 1]
        if key in counts:
            counts[key] = counts[key] + 1
        else:
            counts[key] = 1
        i = i + 1
    return counts


def weighted(counts, k):
    acc = 0
    for key in counts:
        if k == 1:
            code = ord(key)
        else:
            code = ord(key[0]) * 128 + ord(key[1])
        acc = acc + counts[key] * code
    return acc


def knucleotide(n):
    seq = sequence(n)
    return weighted(count_frame(seq, 1), 1) + weighted(count_frame(seq, 2), 2)


if __name__ == "__main__":
    print(knucleotide(N))
