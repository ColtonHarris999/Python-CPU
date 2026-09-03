"""FORMAT_SIMPLE + BUILD_STRING f-string path.

f\"n={n}\" with n=42 → \"n=42\". Host golden compares SHORT_STR identity via
returning the length of the formatted result (4).
"""


def managed_entry():
    n = 42
    s = f"n={n}"
    # "n=42" length 4
    out = 0
    for _ in s:
        out += 1
    return out


managed_entry()
