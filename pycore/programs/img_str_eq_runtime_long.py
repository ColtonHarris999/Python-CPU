"""T0: runtime-built LONG_STR equality and ordering (compiler_design.md 9 T0).

``compiler_design.md`` 2.1 rests the "identifier names may be any length"
decision on ``SA_CMP`` routing two *distinct* LONG_STR objects with matching
``(hash, nbytes, nchars, kind)`` to a content compare. Every LONG_STR in the
image is interned by the builder, so nothing pinned that until this fixture:
the strings here are built at run time by slicing and concatenation, so the
two sides are separate heap objects with different addresses.

``pycore/docs/string_accel.md`` used to claim LONG_STR ordering TYPE-traps;
this is the fixture that says otherwise. Expected result: 63.
"""


def managed_entry():
    src = "alpha_beta_gamma_delta"
    # Two distinct heap objects with identical content: one sliced out of
    # `src`, one rebuilt by concatenation.
    a = src[0:10]
    b = "alpha_" + "beta"
    interned = "alpha_beta"
    out = 0
    if a == b:
        out += 1
    if not (a != b):
        out += 2
    if a == interned:
        out += 4
    if b == interned:
        out += 8
    # Ordering on distinct runtime LONG_STR objects.
    later = src[0:10] + "z"
    if a < later:
        out += 16
    if later > b:
        out += 32
    return out


managed_entry()
