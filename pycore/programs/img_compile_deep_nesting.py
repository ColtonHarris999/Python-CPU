"""40 nested parens parse without a trap (compiler_design.md A3 / step F).

The parser is iterative: operand/operator stacks live in ``_PYC_G``, so this
must not spill the RF. Makefile pins ``+CHECK_RF_SPILL_COUNT=0``. Parens are
not AST nodes, so the tree is Expression wrapping Constant(1).
"""

SRC = "(" * 40 + "1" + ")" * 40


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    g["_in_mode"] = "eval"
    return _bi_exec_globals(g["_pyc_parse_main"], g)


managed_entry()
