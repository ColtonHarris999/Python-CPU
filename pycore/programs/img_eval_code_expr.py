"""eval() an "eval"-mode code object: the expression value comes back.

# pycore-inject: SEED_CODE expr mode=eval source="ev_a * 2 + 1"
"""

ev_a = 20


def managed_entry():
    return eval(expr)


managed_entry()
