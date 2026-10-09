"""List comprehension that grows via LIST_APPEND.

The container accelerator grows the buffer on the pycore side. Expected
result: INT 7.
"""


def managed_entry():
    xs = [i for i in range(8)]
    return xs[7]


managed_entry()
