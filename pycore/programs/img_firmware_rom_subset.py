"""Exercise §4.1 ROM builtins via LOAD_NAME → boot dict → CALL.

Avoids non-empty LIST_EXTEND (literal [1,2,3] from a const tuple) so the
image stays single-core. Locals-built lists use BUILD_LIST.

Host golden: 1137.
"""


def managed_entry():
    total = 0
    total += sum(range(5))  # 10
    total += abs(-7)  # 7 → 17
    if bool(0):
        total += 1
    if bool(42):
        total += 10  # → 27
    x = 1
    y = 2
    xs = [x, y]
    if all(xs):
        total += 100  # → 127
    if all([]):
        total += 10  # → 137
    zs = [0, 1]
    if any(zs):
        total += 1000  # → 1137
    if any([]):
        total += 1
    return total


managed_entry()
