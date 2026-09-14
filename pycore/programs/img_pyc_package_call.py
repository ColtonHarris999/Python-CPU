"""Cross-function call inside ``_PYC_G`` (compiler_design.md step D).

``_PYC_ENTRY`` is a 0-arg trampoline in code RAM whose body is
``return _pyc_add(_pyc_inc(40), 1)``. Helpers resolve in the private
package dict, not the user globals, because ``_bi_exec_globals`` switches
``globals_base_r`` for the call and nested CALL inherits it.
"""


def managed_entry():
    return _bi_exec_globals(_PYC_ENTRY, _PYC_G)


managed_entry()
