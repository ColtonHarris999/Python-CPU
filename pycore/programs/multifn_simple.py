# Test: simple two-function call, callee returns a small integer constant.
# Expected return: 42

def callee():
    return 42


def managed_entry():
    return callee()
