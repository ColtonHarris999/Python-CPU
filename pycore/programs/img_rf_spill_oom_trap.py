# Unbounded recursion with a wide frame. Spill region exhaustion must
# trap MEM_FAULT (7) rather than corrupt the RF or hang.

def fat(n):
    z0 = 0
    z1 = 1
    z2 = 2
    z3 = 3
    z4 = 4
    z5 = 5
    z6 = 6
    z7 = 7
    z8 = 8
    z9 = 9
    z10 = 10
    z11 = 11
    z12 = 12
    z13 = 13
    z14 = 14
    z15 = 15
    z16 = 16
    z17 = 17
    z18 = 18
    z19 = 19
    z20 = 20
    z21 = 21
    z22 = 22
    z23 = 23
    z24 = 24
    z25 = 25
    z26 = 26
    z27 = 27
    z28 = 28
    z29 = 29
    z30 = 30
    z31 = 31
    z32 = 32
    z33 = 33
    z34 = 34
    z35 = 35
    z36 = 36
    z37 = 37
    z38 = 38
    z39 = 39
    z40 = 40
    z41 = 41
    z42 = 42
    z43 = 43
    z44 = 44
    z45 = 45
    z46 = 46
    z47 = 47
    z48 = 48
    z49 = 49
    z50 = 50
    z51 = 51
    z52 = 52
    z53 = 53
    z54 = 54
    z55 = 55
    z56 = 56
    z57 = 57
    z58 = 58
    z59 = 59
    z60 = 60
    z61 = 61
    z62 = 62
    z63 = 63
    z64 = 64
    z65 = 65
    z66 = 66
    z67 = 67
    z68 = 68
    z69 = 69
    z70 = 70
    z71 = 71
    z72 = 72
    z73 = 73
    z74 = 74
    z75 = 75
    z76 = 76
    z77 = 77
    z78 = 78
    z79 = 79
    z80 = 80
    z81 = 81
    z82 = 82
    z83 = 83
    z84 = 84
    z85 = 85
    z86 = 86
    z87 = 87
    z88 = 88
    z89 = 89
    z90 = 90
    z91 = 91
    z92 = 92
    z93 = 93
    z94 = 94
    z95 = 95
    z96 = 96
    z97 = 97
    z98 = 98
    z99 = 99
    return fat(n + 1) + z0


def managed_entry():
    return fat(0)


managed_entry()
