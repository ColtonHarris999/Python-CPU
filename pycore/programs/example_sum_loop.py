# Small image-boot example: a for-loop over a list. Return value is checked
# against host CPython 3.14 when you `make run-file RUN_SOURCE=...`.

def managed_entry():
    total = 0
    for x in [1, 2, 3, 4, 5]:
        total += x
    return total


managed_entry()
