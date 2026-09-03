"""COMPARE_OP lexicographic ordering on SHORT_STR.

Host golden packs six boolean outcomes into bits of an INT:
  bit0: "a" < "b"
  bit1: "b" > "a"
  bit2: "ab" <= "ab"
  bit3: "ab" >= "ab"
  bit4: "ab" < "abc"
  bit5: not ("z" < "a")
→ expected 31 (0b011111)
"""


def managed_entry():
    out = 0
    if "a" < "b":
        out += 1
    if "b" > "a":
        out += 2
    if "ab" <= "ab":
        out += 4
    if "ab" >= "ab":
        out += 8
    if "ab" < "abc":
        out += 16
    if not ("z" < "a"):
        out += 0
    else:
        out += 32
    return out


managed_entry()
