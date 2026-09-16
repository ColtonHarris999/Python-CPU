"""String-form eval() compiles SHORT_STR source (compiler_design.md §11.1).

``eval("1 + 2")`` probes the tag, runs ROM ``compile(..., "eval")``, and
calls the result. Expected: 3.
"""


def managed_entry():
    return eval("1 + 2")


managed_entry()
