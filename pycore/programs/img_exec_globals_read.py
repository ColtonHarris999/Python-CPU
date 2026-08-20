"""exec(code, dict) reads a pre-seeded key from the supplied namespace.

# pycore-inject: SEED_CODE payload mode=exec source="gr_out = gr_in + 1"
"""


def managed_entry():
    ns = {"gr_in": 40, "gr_out": 0}
    exec(payload, ns)
    return ns["gr_out"]


managed_entry()
