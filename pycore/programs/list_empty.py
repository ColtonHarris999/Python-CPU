"""Empty list then [1]; return lst2[0]. Regression for BUILD_LIST 0."""

def managed_entry() -> int:
    lst = []
    lst2 = [1]
    return lst2[0]
