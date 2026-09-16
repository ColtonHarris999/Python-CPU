"""Parser node-count / checksum golden (compiler_design.md step F).

Stores source and ``eval`` mode on ``_PYC_G`` and runs ``_pyc_parse_main``.
The host golden is the firmware parser checksum for ``1 + 2`` (Expression
wrapping BinOp of two Constants).
"""

SRC = "1 + 2"


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    g["_in_mode"] = "eval"
    return _bi_exec_globals(g["_pyc_parse_main"], g)


managed_entry()
