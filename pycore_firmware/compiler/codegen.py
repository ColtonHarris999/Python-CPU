# Firmware T1 codegen + assembler (compiler_design.md §5.5 / step H).
# Recursive visit of nd_* (Rule 2) into ins words in opnd/ops, then
# _bi_code_alloc / blit / new. No CACHE. Jump args compensate for the
# hardware n_cache addend (POP_JUMP=1, JUMP_FORWARD=0).
#
# Instruction shapes follow CPython 3.14 / PyCPython codegen.py (PSF-2.0);
# rewritten over the SoA AST. Nested def is J/T3 — SyntaxError in T1.
#
# Reuses parse scratch after G: opnd/ops/ops_obj = instructions,
# stmts = co_consts, tk_s = co_names, tk_a = label positions, _lex_n =
# label count, _lex_i = current scope, _lex_col = store flag.


def _pyc_emit(op, arg, lab):
    global opnd, opnd_n, ops, ops_obj
    cap = len(opnd)
    while cap < opnd_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        opnd = opnd + ([0] * extra)
        cap = len(opnd)
    cap = len(ops)
    while cap < opnd_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        ops = ops + ([0] * extra)
        ops_obj = ops_obj + ([0] * extra)
        cap = len(ops)
    opnd[opnd_n] = op
    ops[opnd_n] = arg
    ops_obj[opnd_n] = lab
    opnd_n = opnd_n + 1


def _pyc_visit(nid):
    global stmt_n, stmts, tk_n, tk_s, tk_a, _lex_n, _lex_i, _lex_col
    kind = nd_kind[nid]
    store = _lex_col
    if kind == ND["Module"]:
        a = nd_a[nid]
        b = nd_b[nid]
        i = 0
        while i < b:
            _pyc_visit(kids[a + i])
            i = i + 1
        _lex_col = 0
        val = None
        i = 0
        found = 0
        while i < stmt_n:
            if stmts[i] is val:
                _pyc_emit(OPMAP["LOAD_CONST"], i, 0)
                found = 1
                break
            i = i + 1
        if found == 0:
            cap = len(stmts)
            while cap < stmt_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                stmts = stmts + ([0] * extra)
                cap = len(stmts)
            stmts[stmt_n] = val
            _pyc_emit(OPMAP["LOAD_CONST"], stmt_n, 0)
            stmt_n = stmt_n + 1
        _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        return
    if kind == ND["Expression"]:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        return
    if kind == ND["Expr"]:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["POP_TOP"], 0, 0)
        return
    if kind == ND["Assign"]:
        _lex_col = 0
        _pyc_visit(nd_c[nid])
        _lex_col = 1
        _pyc_visit(nd_a[nid])
        _lex_col = 0
        return
    if kind == ND["Return"]:
        a = nd_a[nid]
        if a < 0:
            i = 0
            found = 0
            val = None
            while i < stmt_n:
                if stmts[i] is val:
                    _pyc_emit(OPMAP["LOAD_CONST"], i, 0)
                    found = 1
                    break
                i = i + 1
            if found == 0:
                cap = len(stmts)
                while cap < stmt_n + 1:
                    extra = cap
                    if extra < 8:
                        extra = 8
                    stmts = stmts + ([0] * extra)
                    cap = len(stmts)
                stmts[stmt_n] = val
                _pyc_emit(OPMAP["LOAD_CONST"], stmt_n, 0)
                stmt_n = stmt_n + 1
        else:
            _pyc_visit(a)
        _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        return
    if kind == ND["Global"]:
        return
    if kind == ND["FunctionDef"]:
        _pyc_parse_error("def codegen is not in T1")
        return
    if kind == ND["Constant"]:
        val = nd_obj[nid]
        if isinstance(val, int):
            if val is not True and val is not False:
                if val >= 0 and val <= 255:
                    _pyc_emit(OPMAP["LOAD_SMALL_INT"], val, 0)
                    return
        i = 0
        found = 0
        while i < stmt_n:
            cur = stmts[i]
            same = 0
            if val is True or val is False or val is None:
                if cur is val:
                    same = 1
            else:
                if cur is True or cur is False or cur is None:
                    same = 0
                else:
                    if cur == val:
                        same = 1
            if same:
                _pyc_emit(OPMAP["LOAD_CONST"], i, 0)
                found = 1
                break
            i = i + 1
        if found == 0:
            cap = len(stmts)
            while cap < stmt_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                stmts = stmts + ([0] * extra)
                cap = len(stmts)
            stmts[stmt_n] = val
            _pyc_emit(OPMAP["LOAD_CONST"], stmt_n, 0)
            stmt_n = stmt_n + 1
        return
    if kind == ND["Name"]:
        name = nd_obj[nid]
        sid = _lex_i
        local = 0
        idx = 0
        if sc_kind[sid] == 1:
            names = sc_varnames[sid]
            nloc = sc_nlocals[sid]
            i = 0
            while i < nloc:
                if names[i] == name:
                    local = 1
                    idx = i
                    break
                i = i + 1
        if local:
            if store:
                _pyc_emit(OPMAP["STORE_FAST"], idx, 0)
            else:
                _pyc_emit(OPMAP["LOAD_FAST"], idx, 0)
            return
        i = 0
        ni = 0 - 1
        while i < tk_n:
            if tk_s[i] == name:
                ni = i
                break
            i = i + 1
        if ni < 0:
            cap = len(tk_s)
            while cap < tk_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tk_s = tk_s + ([0] * extra)
                cap = len(tk_s)
            tk_s[tk_n] = name
            ni = tk_n
            tk_n = tk_n + 1
        if sc_kind[sid] == 1:
            if store:
                _pyc_emit(OPMAP["STORE_GLOBAL"], ni, 0)
            else:
                _pyc_emit(OPMAP["LOAD_GLOBAL"], ni * 2, 0)
            return
        if store:
            _pyc_emit(OPMAP["STORE_NAME"], ni, 0)
        else:
            _pyc_emit(OPMAP["LOAD_NAME"], ni, 0)
        return
    if kind == ND["BinOp"]:
        _pyc_visit(nd_a[nid])
        _pyc_visit(nd_c[nid])
        opk = nd_b[nid]
        barg = 0
        if opk == ND["Add"]:
            barg = 0
        elif opk == ND["BitAnd"]:
            barg = 1
        elif opk == ND["FloorDiv"]:
            barg = 2
        elif opk == ND["LShift"]:
            barg = 3
        elif opk == ND["Mult"]:
            barg = 5
        elif opk == ND["Mod"]:
            barg = 6
        elif opk == ND["BitOr"]:
            barg = 7
        elif opk == ND["Pow"]:
            barg = 8
        elif opk == ND["RShift"]:
            barg = 9
        elif opk == ND["Sub"]:
            barg = 10
        elif opk == ND["Div"]:
            barg = 11
        elif opk == ND["BitXor"]:
            barg = 12
        else:
            _pyc_parse_error("unsupported binary op")
        _pyc_emit(OPMAP["BINARY_OP"], barg, 0)
        return
    if kind == ND["UnaryOp"]:
        _pyc_visit(nd_b[nid])
        u = nd_a[nid]
        if u == ND["UAdd"]:
            return
        if u == ND["Not"]:
            _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
            _pyc_emit(OPMAP["UNARY_NOT"], 0, 0)
            return
        if u == ND["USub"]:
            _pyc_emit(OPMAP["UNARY_NEGATIVE"], 0, 0)
            return
        if u == ND["Invert"]:
            _pyc_emit(OPMAP["UNARY_INVERT"], 0, 0)
            return
        _pyc_parse_error("unsupported unary op")
        return
    if kind == ND["BoolOp"]:
        jump = OPMAP["POP_JUMP_IF_FALSE"]
        if nd_a[nid] == ND["Or"]:
            jump = OPMAP["POP_JUMP_IF_TRUE"]
        ks = nd_b[nid]
        n = nd_c[nid]
        _lex_n = _lex_n + 1
        cap = len(tk_a)
        while cap < _lex_n + 1:
            extra = cap
            if extra < 8:
                extra = 8
            tk_a = tk_a + ([0] * extra)
            cap = len(tk_a)
        lab = _lex_n
        i = 0
        while i < n:
            _pyc_visit(kids[ks + i])
            if i < n - 1:
                _pyc_emit(OPMAP["COPY"], 1, 0)
                _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
                _pyc_emit(jump, 0, lab)
                _pyc_emit(OPMAP["POP_TOP"], 0, 0)
            i = i + 1
        tk_a[lab] = opnd_n
        return
    if kind == ND["Compare"]:
        cops = nd_obj[nid]
        n = nd_c[nid]
        ks = nd_b[nid]
        _pyc_visit(nd_a[nid])
        i = 0
        lab = 0
        if n > 1:
            _lex_n = _lex_n + 1
            cap = len(tk_a)
            while cap < _lex_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tk_a = tk_a + ([0] * extra)
                cap = len(tk_a)
            lab = _lex_n
        while i < n:
            _pyc_visit(kids[ks + i])
            opk = cops[i]
            if n > 1 and i < n - 1:
                _pyc_emit(OPMAP["SWAP"], 2, 0)
                _pyc_emit(OPMAP["COPY"], 2, 0)
            if opk == ND["Lt"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 2, 0)
            elif opk == ND["LtE"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 42, 0)
            elif opk == ND["Eq"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 72, 0)
            elif opk == ND["NotEq"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 103, 0)
            elif opk == ND["Gt"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 132, 0)
            elif opk == ND["GtE"]:
                _pyc_emit(OPMAP["COMPARE_OP"], 172, 0)
            elif opk == ND["Is"]:
                _pyc_emit(OPMAP["IS_OP"], 0, 0)
            elif opk == ND["IsNot"]:
                _pyc_emit(OPMAP["IS_OP"], 1, 0)
            elif opk == ND["In"]:
                _pyc_emit(OPMAP["CONTAINS_OP"], 0, 0)
            elif opk == ND["NotIn"]:
                _pyc_emit(OPMAP["CONTAINS_OP"], 1, 0)
            else:
                _pyc_parse_error("unsupported compare op")
            if n > 1 and i < n - 1:
                _pyc_emit(OPMAP["COPY"], 1, 0)
                _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
                _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, lab)
                _pyc_emit(OPMAP["POP_TOP"], 0, 0)
            i = i + 1
        if n > 1:
            _lex_n = _lex_n + 1
            cap = len(tk_a)
            while cap < _lex_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tk_a = tk_a + ([0] * extra)
                cap = len(tk_a)
            end = _lex_n
            _pyc_emit(OPMAP["JUMP_FORWARD"], 0, end)
            tk_a[lab] = opnd_n
            _pyc_emit(OPMAP["SWAP"], 2, 0)
            _pyc_emit(OPMAP["POP_TOP"], 0, 0)
            tk_a[end] = opnd_n
        return
    if kind == ND["Call"]:
        func = nd_a[nid]
        ks = nd_b[nid]
        n = nd_c[nid]
        if nd_kind[func] == ND["Attribute"]:
            _pyc_visit(nd_a[func])
            name = nd_obj[func]
            i = 0
            ni = 0 - 1
            while i < tk_n:
                if tk_s[i] == name:
                    ni = i
                    break
                i = i + 1
            if ni < 0:
                cap = len(tk_s)
                while cap < tk_n + 1:
                    extra = cap
                    if extra < 8:
                        extra = 8
                    tk_s = tk_s + ([0] * extra)
                    cap = len(tk_s)
                tk_s[tk_n] = name
                ni = tk_n
                tk_n = tk_n + 1
            _pyc_emit(OPMAP["LOAD_ATTR"], ni * 2 + 1, 0)
        else:
            _pyc_visit(func)
            _pyc_emit(OPMAP["PUSH_NULL"], 0, 0)
        i = 0
        while i < n:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["CALL"], n, 0)
        return
    if kind == ND["Attribute"]:
        name = nd_obj[nid]
        i = 0
        ni = 0 - 1
        while i < tk_n:
            if tk_s[i] == name:
                ni = i
                break
            i = i + 1
        if ni < 0:
            cap = len(tk_s)
            while cap < tk_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tk_s = tk_s + ([0] * extra)
                cap = len(tk_s)
            tk_s[tk_n] = name
            ni = tk_n
            tk_n = tk_n + 1
        if store:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _lex_col = 1
            _pyc_emit(OPMAP["STORE_ATTR"], ni, 0)
            return
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["LOAD_ATTR"], ni * 2, 0)
        return
    if kind == ND["Subscript"]:
        if store:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _lex_col = 1
            _pyc_emit(OPMAP["STORE_SUBSCR"], 0, 0)
            return
        _pyc_visit(nd_a[nid])
        _pyc_visit(nd_b[nid])
        _pyc_emit(OPMAP["BINARY_OP"], 26, 0)
        return
    _pyc_parse_error("unsupported node in codegen")


def _pyc_assemble():
    i = 0
    while i < opnd_n:
        lab = ops_obj[i]
        if lab:
            op = opnd[i]
            tgt = tk_a[lab]
            nc = 0
            if op != OPMAP["JUMP_FORWARD"]:
                nc = 1
            if tgt >= i:
                ops[i] = tgt - i - 1 - nc
            else:
                ops[i] = i + 1 + nc - tgt
        i = i + 1
    depth = 0
    maxd = 0
    i = 0
    while i < opnd_n:
        op = opnd[i]
        arg = ops[i]
        d = 0
        if (
            op == OPMAP["LOAD_SMALL_INT"]
            or op == OPMAP["LOAD_CONST"]
            or op == OPMAP["LOAD_NAME"]
            or op == OPMAP["LOAD_GLOBAL"]
            or op == OPMAP["LOAD_FAST"]
            or op == OPMAP["PUSH_NULL"]
            or op == OPMAP["COPY"]
        ):
            d = 1
        elif op == OPMAP["LOAD_ATTR"]:
            if arg & 1:
                d = 1
        elif (
            op == OPMAP["STORE_NAME"]
            or op == OPMAP["STORE_GLOBAL"]
            or op == OPMAP["STORE_FAST"]
            or op == OPMAP["POP_TOP"]
            or op == OPMAP["POP_JUMP_IF_FALSE"]
            or op == OPMAP["POP_JUMP_IF_TRUE"]
            or op == OPMAP["BINARY_OP"]
            or op == OPMAP["COMPARE_OP"]
            or op == OPMAP["IS_OP"]
            or op == OPMAP["CONTAINS_OP"]
            or op == OPMAP["RETURN_VALUE"]
        ):
            d = 0 - 1
        elif op == OPMAP["STORE_ATTR"]:
            d = 0 - 2
        elif op == OPMAP["STORE_SUBSCR"]:
            d = 0 - 3
        elif op == OPMAP["CALL"]:
            d = 0 - (arg + 1)
        depth = depth + d
        if depth < 0:
            depth = 0
        if depth > maxd:
            maxd = depth
        i = i + 1
    nloc = sc_nlocals[_lex_i]
    if nloc + maxd > 240:
        _pyc_parse_error("frame window too large")
    if maxd < 1:
        maxd = 1
    words = [0] * opnd_n
    i = 0
    while i < opnd_n:
        words[i] = (ops[i] << 8) | (opnd[i] & 255)
        i = i + 1
    consts = tuple(copy_range(stmts, 0, stmt_n))
    names = tuple(copy_range(tk_s, 0, tk_n))
    vn = sc_varnames[_lex_i]
    varnames = tuple(copy_range(vn, 0, nloc))
    meta = (maxd << 32) | (nloc << 16) | sc_argcount[_lex_i]
    base = _bi_code_alloc(opnd_n)
    _bi_code_blit(base, words)
    return _bi_code_new(
        [base, consts, names, meta, (), varnames, {}, (), 0]
    )


def _pyc_codegen_main():
    global opnd_n, opnd, ops, ops_obj, stmt_n, stmts, tk_n, tk_s, tk_a
    global _lex_n, _lex_i, _lex_col
    _pyc_lex(_in_src)
    root = _pyc_parse(_in_mode)
    _pyc_symtab(root)
    opnd_n = 0
    opnd = [0] * 8
    ops = [0] * 8
    ops_obj = [0] * 8
    stmt_n = 0
    stmts = [0] * 8
    tk_n = 0
    tk_s = [0] * 8
    tk_a = [0] * 8
    _lex_n = 0
    _lex_i = 0
    _lex_col = 0
    _pyc_emit(OPMAP["RESUME"], 0, 0)
    _pyc_visit(root)
    return _pyc_assemble()
