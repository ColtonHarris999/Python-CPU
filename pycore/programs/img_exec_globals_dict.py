"""exec(code, dict) writes into the dict; module globals stay put.

# pycore-inject: SEED_CODE payload mode=exec source="gd_x = 77"
"""

gd_x = 1


def managed_entry():
    ns = {"gd_x": 0}
    exec(payload, ns)
    return gd_x * 100 + ns["gd_x"]


managed_entry()
