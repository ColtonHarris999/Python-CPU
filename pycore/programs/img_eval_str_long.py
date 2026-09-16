"""String-form eval() of a LONG_STR source (compiler_design.md §11.1).

``"1 + 2 + 3 + 4 + 5"`` is 17 UTF-8 bytes, so ``_bi_code_kind`` returns 8.
Expected: 15.
"""


def managed_entry():
    return eval("1 + 2 + 3 + 4 + 5")


managed_entry()
