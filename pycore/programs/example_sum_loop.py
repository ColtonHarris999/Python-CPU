# Small image-boot example: a for-loop over a list. The return value is checked
# against host CPython 3.14 by `make run-file RUN_SOURCE=... HOST_COMPILE=1`.

def managed_entry():
    total = 0
    for x in [1, 2, 3, 4, 5]:
        total += x
    return total


managed_entry()
