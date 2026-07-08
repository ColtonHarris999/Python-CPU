# Test: callee returns a value loaded via LOAD_CONST (inline encoded constant).
# Expected return: 1337

def callee():
    return 1337


def managed_entry():
    return callee()
