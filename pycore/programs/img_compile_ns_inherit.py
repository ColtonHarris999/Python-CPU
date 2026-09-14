"""T0 (b): helper CALL under ``_bi_exec_globals`` resolves in the supplied dict.

``helper`` LOAD_GLOBALs ``secret``. The module global is 0; the exec dict
has 41. Device CALL inherits ``globals_base_r`` from the exec frame, so
the helper sees 41 and returns 42.

Host CPython functions keep their defining globals, so the host result
would be 1. Pin the *device* contract with ``pycore-expect``.

# pycore-expect: 42
# pycore-inject: SEED_CODE payload mode=exec source="ni_out = helper()"
"""

secret = 0


def helper():
    return secret + 1


def managed_entry():
    ns = {"secret": 41, "helper": helper, "ni_out": 0}
    exec(payload, ns)
    return ns["ni_out"]


managed_entry()
