"""Bare raise without an active exception remains fatal PY_TRAP_RAISE (17)."""


def managed_entry():
    raise


managed_entry()
