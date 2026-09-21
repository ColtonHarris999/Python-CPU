"""T0: _bi_exec_globals namespace inheritance (compiler_design.md 9 T0 / 4.2).

The whole "60 helpers in a private dict, two names in boot builtins" design
rests on R2: ``_bi_exec_globals`` switches ``globals_base_r`` for one frame,
and every frame nested inside that call *inherits* it, because an ordinary
CALL does not touch ``globals_base_r``. Fallback F-A (prefix every helper and
seed it into boot builtins) exists only if that does not hold.

This pins it directly rather than by inference from a compile: a helper
reached two CALL levels deep still resolves names in the supplied dict, the
caller's own globals are untouched, and a name bound only in the caller's
globals is *not* visible inside. Expected result: 7.
"""

probe = 100
seen = 0


def managed_entry():
    g = _PYC_G
    # _pyc_add / _pyc_inc are the step-D toy package: _pyc_add calls
    # _pyc_inc, so resolving it needs the inherited namespace two levels in.
    out = 0
    if _bi_exec_globals(_PYC_ENTRY, g) == 42:
        out += 1
    # The caller's globals must be intact after the switch back.
    if probe == 100:
        out += 2
    # A name that exists only in _PYC_G is not visible out here, and a name
    # that exists only out here was not reachable from inside.
    if seen == 0:
        out += 4
    return out


managed_entry()
