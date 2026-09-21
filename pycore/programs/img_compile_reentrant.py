"""D9: the compile() re-entrancy guard, and that it never false-fires.

``_in_src`` / ``_in_file`` / ``_in_mode`` and every compiler arena live on
``_PYC_G``, so a ``compile()`` entered while another is still on the stack
would overwrite the outer call's source mid-parse. The ``_busy`` flag in the
ROM shim makes that a ``ValueError`` instead of a miscompile.

No path reaches it today -- ``exec(compile(src))`` is sequential, not
nested, and the compiler never calls ``compile`` -- so what this fixture
pins is the part that *can* go wrong: the guard must not fire on ordinary
back-to-back compiles, must be cleared by ``finally`` after a failed one,
and must still reject an entry that really does find the flag set.

Each ``try`` lives in its own function: two sequential ``try`` blocks in one
body make CPython emit ``JUMP_BACKWARD_NO_INTERRUPT``, which this target
rejects (`validate_code_object`).

Expected result: 7.
"""


def failed_compile_clears_busy():
    """A compile that raises must leave _busy clear for the next one."""
    try:
        compile("import os", "<s>", "exec")
    except SyntaxError:
        return _PYC_G["_busy"] == 0
    return False


def entry_while_busy_is_refused():
    """With the flag set, entry is refused rather than clobbering the slots."""
    g = _PYC_G
    g["_busy"] = 1
    try:
        compile("1 + 2", "<s>", "eval")
    except ValueError:
        g["_busy"] = 0
        return True
    g["_busy"] = 0
    return False


def managed_entry():
    out = 0
    if failed_compile_clears_busy():
        out += 1
    # Back-to-back compiles do not trip the guard.
    if eval(compile("3 + 4", "<s>", "eval")) == 7:
        out += 2
    if entry_while_busy_is_refused():
        out += 4
    return out


managed_entry()
