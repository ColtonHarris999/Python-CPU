"""String-form exec() compiles then STORE_NAMEs into module globals.

``exec("x = 1 + 2")`` is SHORT_STR. Pre-bind ``x`` so the compiled program
overwrites an existing key (single-core dicts cannot grow). Expected: 3.
"""

x = 0


def managed_entry():
    exec("x = 1 + 2")
    return x


managed_entry()
