# Compile suite T1: literals, arithmetic, comparisons, boolean logic,
# identity and membership, and constant folding.
a = 17
b = 5
print("add sub", a + b, a - b)
print("mul div", a * b, a // b, a % b)
print("pow", 2 ** 10, (-3) ** 3)
print("bits", a & b, a | b, a ^ b, ~a)
print("shift", a << 3, a >> 2)
print("neg", -a, +b, -(-a))
print("fold", 1 + 2 * 3 - 4, 7 & 3 | 8)
print("cmp", a < b, a > b, a == 17, a != 17)
print("chain", 1 < b < a, 1 < a < b, b <= 5 <= a)
print("bool", a > 1 and b > 1, a < 1 or b < 1, not a)
print("short", 0 and 1 / 0, 1 or 1 / 0)
x = None
print("is", x is None, x is not None, a is a)
xs = [1, 2, 3]
print("in", 2 in xs, 5 in xs, 5 not in xs)
# Ints are 64-bit on the hart, but print() formats 32 bits: print the
# high part to prove the arithmetic kept it.
print("big", (2 ** 40 + 1) >> 20, (2 ** 40) // 2 ** 30, -(2 ** 40) < 0)
s = "abc"
print("str", s + "de", len(s))
# Adjacent literals longer than 15 characters are one LOAD_CONST.
joined = (
    "0123456789abcdef"
    "0123456789"
)
print("join", len(joined), ord(joined[16]))
print("strcmp", s == "abc", s < "abd", "b" in s)
print("index", s[0], s[2], s[-1])
print("slice", s[1:], s[:2], "hello"[1:4])
print("ternary", 1 if a > b else 2, 1 if a < b else 2)
