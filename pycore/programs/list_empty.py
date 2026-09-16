"""Empty list then [1]; return lst2[0]. Regression for BUILD_LIST 0.

Expected: INT 1
"""


def managed_entry():
    lst = []
    lst2 = [1]
    return lst2[0]


managed_entry()
