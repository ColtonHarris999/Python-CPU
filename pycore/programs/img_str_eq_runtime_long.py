"""T0 (a): runtime LONG_STR content equality and lexicographic ordering.

Interned constants that share a handle already compare equal (``img_str_eq``).
This pins the STRACC ``SA_CMP`` path for *distinct* LONG objects — runtime
concat vs an interned copy of the same text — plus LONG ``<`` / ``>`` / ``<=``.

Host golden packs six booleans:
  bit0: interned == runtime concat (same text, distinct objects)
  bit1: interned != a different LONG
  bit2: interned < a later LONG (ordering, interned)
  bit3: runtime concat < a later runtime LONG (ordering, runtime)
  bit4: later runtime LONG > interned
  bit5: interned <= runtime concat (equal content)
→ expected 63
"""


def managed_entry():
    interned = "this is a long string!!"
    runtime = "this is a " + "long string!!"
    other = "zzzzzzzzzzzzzzzzzzzzzz"
    runtime_other = "zzzzzzzzzz" + "zzzzzzzzzzzz"
    out = 0
    if interned == runtime:
        out += 1
    if interned != other:
        out += 2
    if interned < other:
        out += 4
    if runtime < runtime_other:
        out += 8
    if runtime_other > interned:
        out += 16
    if interned <= runtime:
        out += 32
    return out


managed_entry()
