"""Two levels of exec(..., dict) with distinct namespaces.

# pycore-inject: SEED_CODE inner mode=exec source="n2_v = n2_v + 4"
# pycore-inject: SEED_CODE outer mode=exec source="n1_v = n1_v + 3\nexec(inner, n2)"
"""

n1_v = 1
n2_v = 2


def managed_entry():
    n2 = {"n2_v": 10}
    n1 = {"n1_v": 20, "inner": inner, "n2": n2}
    exec(outer, n1)
    if n1_v != 1:
        return 0
    if n2_v != 2:
        return 0
    return n1["n1_v"] * 100 + n2["n2_v"]


managed_entry()
