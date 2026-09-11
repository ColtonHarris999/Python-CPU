"""PyBGL damerau_levenshtein_distance_naive slice shape: `x[1:]` / `x[2:]`.

Those all-literal slices used to image-reject (`Unsupported constant slice`).
"""


def managed_entry():
    x = "ab"
    y = "ac"
    x_1 = x[1:]
    y_1 = y[1:]
    total = 0
    if x_1 == "b":
        total += 1
    if y_1 == "c":
        total += 10
    z = "abcd"
    if z[2:] == "cd":
        total += 100
    return total


managed_entry()
