"""Execute a precompiled code object for its side effects; returns None.

Needs no hardware support beyond what already exists. ``CALL`` on a
``CODE_OBJECT`` held in a variable works (see ``filter``'s predicate), and a
module-mode code object's ``STORE_NAME`` / ``LOAD_NAME`` already target the
boot-record globals dict -- which *is* module-scope ``exec`` semantics.

The string form (``exec("x = 1")``) needs runtime ``compile()`` and is Plan 2;
see ``planning/native_compiler_plan.md`` §8.1.

Host note: CPython code objects are not callable, so ``run_image_test.py``
overrides this body with a stand-in bound to the test program's globals. The
device runs this source.
"""


def exec(code):
    code()
    return None
