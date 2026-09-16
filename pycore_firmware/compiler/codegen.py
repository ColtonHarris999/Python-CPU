# Firmware T1–T4 codegen + assembler (compiler_design.md §5.5 / steps H, J, T4).
# Recursive visit of nd_* (Rule 2) into ins words in opnd/ops, then
# _bi_code_alloc / blit / new. No CACHE. Jump args compensate for the
# hardware n_cache addend (POP_JUMP/JUMP_BACKWARD/FOR_ITER=1, JUMP_FORWARD=0).
#
# Instruction shapes follow CPython 3.14 / PyCPython codegen.py (PSF-2.0);
# rewritten over the SoA AST. Nested def is assembled depth-first into
# the parent's co_consts, then MAKE_FUNCTION (device: function ≡ code).
#
# Reuses parse scratch after G: opnd/ops/ops_obj = instructions,
# stmts = co_consts, tk_s = co_names, tk_a = label positions, _lex_n =
# label count, _lex_i = current scope, _lex_col = store/del flag
# (0 load, 1 store, 2 del), _lex_line = loop depth, tk_b = break/continue
# label pairs.


def _pyc_emit(op, arg, lab):
    global opnd, opnd_n, ops, ops_obj, tk_a, _lex_n
    if lab < 0:
        _lex_n = _lex_n + 1
        cap = len(tk_a)
        while cap < _lex_n + 1:
            extra = cap
            if extra < 8:
                extra = 8
            tk_a = tk_a + ([0] * extra)
            cap = len(tk_a)
        lab = _lex_n
    if op < 0:
        return lab
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
    return lab


def _pyc_visit(nid):
    global stmt_n, stmts, tk_n, tk_s, tk_a, tk_b, _lex_n, _lex_i, _lex_col
    global _lex_line, opnd, ops, ops_obj, opnd_n, kids_n
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
        sv_opnd = opnd
        sv_ops = ops
        sv_ops_obj = ops_obj
        sv_opnd_n = opnd_n
        sv_stmts = stmts
        sv_stmt_n = stmt_n
        sv_tk_s = tk_s
        sv_tk_n = tk_n
        sv_tk_a = tk_a
        sv_tk_b = tk_b
        sv_lex_n = _lex_n
        sv_lex_i = _lex_i
        sv_lex_col = _lex_col
        sv_lex_line = _lex_line
        sv_kids_n = kids_n
        sid = 0
        i = 0
        found = 0
        while i < sc_n:
            if sc_node[i] == nid:
                sid = i
                found = 1
                break
            i = i + 1
        if found == 0:
            _pyc_parse_error("function scope missing")
        opnd_n = 0
        opnd = [0] * 8
        ops = [0] * 8
        ops_obj = [0] * 8
        stmt_n = 0
        stmts = [0] * 8
        tk_n = 0
        tk_s = [0] * 8
        tk_a = [0] * 8
        tk_b = [0] * 8
        tk_b[0] = kids_n
        _lex_n = 0
        _lex_i = sid
        _lex_col = 0
        _lex_line = 0
        _pyc_emit(OPMAP["RESUME"], 0, 0)
        ks = nd_a[nid]
        nargs = nd_b[nid]
        nbody = nd_c[nid]
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + nargs + i])
            i = i + 1
        none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
        _pyc_visit(none_id)
        _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        child = _pyc_assemble()
        opnd = sv_opnd
        ops = sv_ops
        ops_obj = sv_ops_obj
        opnd_n = sv_opnd_n
        stmts = sv_stmts
        stmt_n = sv_stmt_n
        tk_s = sv_tk_s
        tk_n = sv_tk_n
        tk_a = sv_tk_a
        tk_b = sv_tk_b
        _lex_n = sv_lex_n
        _lex_i = sv_lex_i
        _lex_col = sv_lex_col
        _lex_line = sv_lex_line
        kids_n = sv_kids_n
        cap = len(stmts)
        while cap < stmt_n + 1:
            extra = cap
            if extra < 8:
                extra = 8
            stmts = stmts + ([0] * extra)
            cap = len(stmts)
        stmts[stmt_n] = child
        _pyc_emit(OPMAP["LOAD_CONST"], stmt_n, 0)
        stmt_n = stmt_n + 1
        _pyc_emit(OPMAP["MAKE_FUNCTION"], 0, 0)
        name_id = _pyc_nd_new(
            ND["Name"], 1, 0, ND["Store"], 0, 0, nd_obj[nid]
        )
        _lex_col = 1
        _pyc_visit(name_id)
        _lex_col = 0
        return
    if kind == ND["Constant"]:
        val = nd_obj[nid]
        if nd_a[nid] == 0:
            if val >= 0:
                if val <= 255:
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
            if store == 1:
                _pyc_emit(OPMAP["STORE_FAST"], idx, 0)
            elif store == 2:
                _pyc_emit(OPMAP["DELETE_FAST"], idx, 0)
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
            if store == 1:
                _pyc_emit(OPMAP["STORE_GLOBAL"], ni, 0)
            elif store == 2:
                _pyc_parse_error("del of a global name is not supported")
            else:
                _pyc_emit(OPMAP["LOAD_GLOBAL"], ni * 2, 0)
            return
        if store == 1:
            _pyc_emit(OPMAP["STORE_NAME"], ni, 0)
        elif store == 2:
            _pyc_parse_error("del of a global name is not supported")
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
        if store == 1:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _lex_col = 1
            _pyc_emit(OPMAP["STORE_ATTR"], ni, 0)
            return
        if store == 2:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _lex_col = 2
            _pyc_emit(OPMAP["DELETE_ATTR"], ni, 0)
            return
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["LOAD_ATTR"], ni * 2, 0)
        return
    if kind == ND["Subscript"]:
        slc = nd_b[nid]
        if nd_kind[slc] == ND["Slice"]:
            if store != 0:
                _pyc_parse_error("slice assignment is not supported")
            _pyc_visit(nd_a[nid])
            lo = nd_a[slc]
            hi = nd_b[slc]
            if lo < 0:
                none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
                _pyc_visit(none_id)
            else:
                _pyc_visit(lo)
            if hi < 0:
                none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
                _pyc_visit(none_id)
            else:
                _pyc_visit(hi)
            _pyc_emit(OPMAP["BINARY_SLICE"], 0, 0)
            return
        if store == 1:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _lex_col = 1
            _pyc_emit(OPMAP["STORE_SUBSCR"], 0, 0)
            return
        if store == 2:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _lex_col = 2
            _pyc_emit(OPMAP["DELETE_SUBSCR"], 0, 0)
            return
        _pyc_visit(nd_a[nid])
        _pyc_visit(nd_b[nid])
        _pyc_emit(OPMAP["BINARY_OP"], 26, 0)
        return
    if kind == ND["Slice"]:
        _pyc_parse_error("slice outside subscript")
        return
    if kind == ND["Pass"]:
        return
    if kind == ND["Break"]:
        if _lex_line < 1:
            _pyc_parse_error("'break' outside loop")
        br = tk_b[_lex_line * 2]
        _pyc_emit(OPMAP["JUMP_FORWARD"], 0, br)
        return
    if kind == ND["Continue"]:
        if _lex_line < 1:
            _pyc_parse_error("'continue' not properly in loop")
        cont = tk_b[_lex_line * 2 + 1]
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        return
    if kind == ND["If"]:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        else_lab = _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, 0 - 1)
        ks = nd_b[nid]
        nbody = nd_c[nid]
        norelse = nd_obj[nid]
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        if norelse:
            end_lab = _pyc_emit(OPMAP["JUMP_FORWARD"], 0, 0 - 1)
            tk_a[else_lab] = opnd_n
            i = 0
            while i < norelse:
                _pyc_visit(kids[ks + nbody + i])
                i = i + 1
            tk_a[end_lab] = opnd_n
        else:
            tk_a[else_lab] = opnd_n
        return
    if kind == ND["While"]:
        br = _pyc_emit(0 - 1, 0, 0 - 1)
        cont = _pyc_emit(0 - 1, 0, 0 - 1)
        _lex_line = _lex_line + 1
        if len(tk_b) < _lex_line * 2 + 2:
            tk_b = tk_b + ([0] * 8)
        tk_b[_lex_line * 2] = br
        tk_b[_lex_line * 2 + 1] = cont
        tk_a[cont] = opnd_n
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, br)
        ks = nd_b[nid]
        nbody = nd_c[nid]
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        tk_a[br] = opnd_n
        _lex_line = _lex_line - 1
        return
    if kind == ND["For"]:
        endfor = _pyc_emit(0 - 1, 0, 0 - 1)
        popiter = _pyc_emit(0 - 1, 0, 0 - 1)
        cont = _pyc_emit(0 - 1, 0, 0 - 1)
        _lex_line = _lex_line + 1
        if len(tk_b) < _lex_line * 2 + 2:
            tk_b = tk_b + ([0] * 8)
        tk_b[_lex_line * 2] = popiter
        tk_b[_lex_line * 2 + 1] = cont
        _pyc_visit(nd_b[nid])
        _pyc_emit(OPMAP["GET_ITER"], 0, 0)
        tk_a[cont] = opnd_n
        _pyc_emit(OPMAP["FOR_ITER"], 0, endfor)
        _lex_col = 1
        _pyc_visit(nd_a[nid])
        _lex_col = 0
        ks = nd_c[nid]
        nbody = nd_obj[nid]
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        tk_a[endfor] = opnd_n
        _pyc_emit(OPMAP["END_FOR"], 0, 0)
        tk_a[popiter] = opnd_n
        _pyc_emit(OPMAP["POP_ITER"], 0, 0)
        _lex_line = _lex_line - 1
        return
    if kind == ND["AugAssign"]:
        if nd_kind[nd_a[nid]] != ND["Name"]:
            _pyc_parse_error("unsupported augmented assignment target")
        _lex_col = 0
        _pyc_visit(nd_a[nid])
        _pyc_visit(nd_c[nid])
        opk = nd_b[nid]
        barg = 13
        if opk == ND["Add"]:
            barg = 13
        elif opk == ND["BitAnd"]:
            barg = 14
        elif opk == ND["FloorDiv"]:
            barg = 15
        elif opk == ND["LShift"]:
            barg = 16
        elif opk == ND["Mult"]:
            barg = 18
        elif opk == ND["Mod"]:
            barg = 19
        elif opk == ND["BitOr"]:
            barg = 20
        elif opk == ND["Pow"]:
            barg = 21
        elif opk == ND["RShift"]:
            barg = 22
        elif opk == ND["Sub"]:
            barg = 23
        elif opk == ND["Div"]:
            barg = 24
        elif opk == ND["BitXor"]:
            barg = 25
        else:
            _pyc_parse_error("unsupported augmented op")
        _pyc_emit(OPMAP["BINARY_OP"], barg, 0)
        _lex_col = 1
        _pyc_visit(nd_a[nid])
        _lex_col = 0
        return
    if kind == ND["Delete"]:
        ks = nd_a[nid]
        n = nd_b[nid]
        i = 0
        while i < n:
            _lex_col = 2
            _pyc_visit(kids[ks + i])
            i = i + 1
        _lex_col = 0
        return
    if kind == ND["List"] or kind == ND["Tuple"] or kind == ND["Set"]:
        n = nd_b[nid]
        ks = nd_a[nid]
        if store == 1:
            _pyc_emit(OPMAP["UNPACK_SEQUENCE"], n, 0)
            i = 0
            while i < n:
                _lex_col = 1
                _pyc_visit(kids[ks + i])
                i = i + 1
            _lex_col = 1
            return
        i = 0
        while i < n:
            _lex_col = 0
            _pyc_visit(kids[ks + i])
            i = i + 1
        if kind == ND["List"]:
            _pyc_emit(OPMAP["BUILD_LIST"], n, 0)
        elif kind == ND["Tuple"]:
            _pyc_emit(OPMAP["BUILD_TUPLE"], n, 0)
        else:
            _pyc_emit(OPMAP["BUILD_SET"], n, 0)
        return
    if kind == ND["Dict"]:
        n = nd_b[nid]
        ks = nd_a[nid]
        i = 0
        while i < n * 2:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["BUILD_MAP"], n, 0)
        return
    if kind == ND["Raise"]:
        a = nd_a[nid]
        if a < 0:
            _pyc_emit(OPMAP["RAISE_VARARGS"], 0, 0)
        else:
            _pyc_visit(a)
            _pyc_emit(OPMAP["RAISE_VARARGS"], 1, 0)
        return
    if kind == ND["ListComp"] or kind == ND["SetComp"] or kind == ND["DictComp"]:
        if kind == ND["DictComp"]:
            _pyc_visit(nd_obj[nid])
        else:
            _pyc_visit(nd_c[nid])
        _pyc_emit(OPMAP["GET_ITER"], 0, 0)
        if kind == ND["ListComp"]:
            _pyc_emit(OPMAP["BUILD_LIST"], 0, 0)
        elif kind == ND["SetComp"]:
            _pyc_emit(OPMAP["BUILD_SET"], 0, 0)
        else:
            _pyc_emit(OPMAP["BUILD_MAP"], 0, 0)
        _pyc_emit(OPMAP["SWAP"], 2, 0)
        endfor = _pyc_emit(0 - 1, 0, 0 - 1)
        cont = _pyc_emit(0 - 1, 0, 0 - 1)
        tk_a[cont] = opnd_n
        _pyc_emit(OPMAP["FOR_ITER"], 0, endfor)
        _lex_col = 1
        if kind == ND["DictComp"]:
            _pyc_visit(nd_c[nid])
        else:
            _pyc_visit(nd_b[nid])
        _lex_col = 0
        if kind == ND["DictComp"]:
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _pyc_emit(OPMAP["MAP_ADD"], 2, 0)
        elif kind == ND["ListComp"]:
            _pyc_visit(nd_a[nid])
            _pyc_emit(OPMAP["LIST_APPEND"], 2, 0)
        else:
            _pyc_visit(nd_a[nid])
            _pyc_emit(OPMAP["SET_ADD"], 2, 0)
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        tk_a[endfor] = opnd_n
        _pyc_emit(OPMAP["END_FOR"], 0, 0)
        _pyc_emit(OPMAP["POP_ITER"], 0, 0)
        return
    if kind == ND["Try"]:
        nbody = nd_b[nid]
        nh = nd_c[nid]
        norelse = nd_obj[nid] & 65535
        nfinal = nd_obj[nid] >> 16
        ks = nd_a[nid]
        else_lab = _pyc_emit(0 - 1, 0, 0 - 1)
        done_lab = _pyc_emit(0 - 1, 0, 0 - 1)
        try_start = opnd_n
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        try_end = opnd_n
        _pyc_emit(OPMAP["JUMP_FORWARD"], 0, else_lab)
        handler = opnd_n
        _pyc_emit(OPMAP["PUSH_EXC_INFO"], 0, 0)
        if nh < 1:
            i = 0
            while i < nfinal:
                _pyc_visit(kids[ks + nbody + nh + norelse + i])
                i = i + 1
            _pyc_emit(OPMAP["RERAISE"], 0, 0)
        else:
            hi = 0
            while hi < nh:
                h = kids[ks + nbody + hi]
                typ = nd_a[h]
                miss = 0
                if typ >= 0:
                    _pyc_visit(typ)
                    _pyc_emit(OPMAP["CHECK_EXC_MATCH"], 0, 0)
                    miss = _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, 0 - 1)
                hname = nd_obj[h]
                if hname != 0:
                    name_id = _pyc_nd_new(
                        ND["Name"], 1, 0, ND["Store"], 0, 0, hname
                    )
                    _lex_col = 1
                    _pyc_visit(name_id)
                    _lex_col = 0
                else:
                    _pyc_emit(OPMAP["POP_TOP"], 0, 0)
                hks = nd_b[h]
                hn = nd_c[h]
                j = 0
                while j < hn:
                    _pyc_visit(kids[hks + j])
                    j = j + 1
                _pyc_emit(OPMAP["POP_EXCEPT"], 0, 0)
                i = 0
                while i < nfinal:
                    _pyc_visit(kids[ks + nbody + nh + norelse + i])
                    i = i + 1
                _pyc_emit(OPMAP["JUMP_FORWARD"], 0, done_lab)
                if typ >= 0:
                    tk_a[miss] = opnd_n
                hi = hi + 1
            _pyc_emit(OPMAP["RERAISE"], 0, 0)
        cleanup = opnd_n
        _pyc_emit(OPMAP["COPY"], 3, 0)
        _pyc_emit(OPMAP["POP_EXCEPT"], 0, 0)
        _pyc_emit(OPMAP["RERAISE"], 1, 0)
        tk_a[else_lab] = opnd_n
        i = 0
        while i < norelse:
            _pyc_visit(kids[ks + nbody + nh + i])
            i = i + 1
        i = 0
        while i < nfinal:
            _pyc_visit(kids[ks + nbody + nh + norelse + i])
            i = i + 1
        tk_a[done_lab] = opnd_n
        _pyc_kids_append(try_start)
        _pyc_kids_append(try_end)
        _pyc_kids_append(handler)
        _pyc_kids_append(0)
        _pyc_kids_append(0)
        _pyc_kids_append(handler)
        _pyc_kids_append(cleanup)
        _pyc_kids_append(cleanup)
        _pyc_kids_append(1)
        _pyc_kids_append(1)
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
            or op == OPMAP["FOR_ITER"]
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
            or op == OPMAP["END_FOR"]
            or op == OPMAP["POP_ITER"]
            or op == OPMAP["DELETE_ATTR"]
        ):
            d = 0 - 1
        elif op == OPMAP["STORE_ATTR"] or op == OPMAP["DELETE_SUBSCR"]:
            d = 0 - 2
        elif op == OPMAP["STORE_SUBSCR"]:
            d = 0 - 3
        elif op == OPMAP["CALL"]:
            d = 0 - (arg + 1)
        elif (
            op == OPMAP["BUILD_LIST"]
            or op == OPMAP["BUILD_TUPLE"]
            or op == OPMAP["BUILD_SET"]
        ):
            d = 1 - arg
        elif op == OPMAP["BUILD_MAP"]:
            d = 1 - (arg * 2)
        elif op == OPMAP["UNPACK_SEQUENCE"]:
            d = arg - 1
        elif op == OPMAP["BINARY_SLICE"]:
            d = 0 - 2
        elif (
            op == OPMAP["LIST_APPEND"]
            or op == OPMAP["SET_ADD"]
            or op == OPMAP["POP_EXCEPT"]
        ):
            d = 0 - 1
        elif op == OPMAP["MAP_ADD"]:
            d = 0 - 2
        elif op == OPMAP["RAISE_VARARGS"]:
            if arg == 1:
                d = 0 - 1
        elif op == OPMAP["PUSH_EXC_INFO"] or op == OPMAP["COPY"]:
            d = 1
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
    # tuple(list) is LIST_EXTEND on device (trap 10). Concat of 1-tuples
    # is BUILD_TUPLE 1 + BINARY_OP add, which the subset already runs.
    consts = ()
    i = 0
    while i < stmt_n:
        consts = consts + (stmts[i],)
        i = i + 1
    names = ()
    i = 0
    while i < tk_n:
        names = names + (tk_s[i],)
        i = i + 1
    vn = sc_varnames[_lex_i]
    varnames = ()
    i = 0
    while i < nloc:
        varnames = varnames + (vn[i],)
        i = i + 1
    meta = (maxd << 32) | (nloc << 16) | sc_argcount[_lex_i]
    base = _bi_code_alloc(opnd_n)
    _bi_code_blit(base, words)
    exctable = ()
    ei = tk_b[0]
    while ei + 4 < kids_n:
        start = kids[ei]
        end = kids[ei + 1]
        target = kids[ei + 2]
        depthv = kids[ei + 3]
        lasti = kids[ei + 4]
        fields = [0] * 4
        fields[0] = start
        fields[1] = end - start
        fields[2] = target
        fields[3] = (depthv << 1) | lasti
        fi = 0
        while fi < 4:
            val = fields[fi]
            chunks = [0] * 8
            cn = 0
            chunks[0] = val & 63
            val = val >> 6
            cn = 1
            while val:
                cap = len(chunks)
                while cap < cn + 1:
                    extra = cap
                    if extra < 8:
                        extra = 8
                    chunks = chunks + ([0] * extra)
                    cap = len(chunks)
                chunks[cn] = val & 63
                val = val >> 6
                cn = cn + 1
            # reverse: last written is MSB
            ri = cn
            while ri > 0:
                ri = ri - 1
                b = chunks[ri]
                if ri != 0:
                    b = b | 64
                if fi == 0:
                    if ri == cn - 1:
                        b = b | 128
                exctable = exctable + (b,)
            fi = fi + 1
        ei = ei + 5
    return _bi_code_new(
        [base, consts, names, meta, (), varnames, {}, exctable, 0]
    )


def _pyc_codegen_main():
    global opnd_n, opnd, ops, ops_obj, stmt_n, stmts, tk_n, tk_s, tk_a, tk_b
    global _lex_n, _lex_i, _lex_col, _lex_line
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
    tk_b = [0] * 8
    tk_b[0] = kids_n
    _lex_n = 0
    _lex_i = 0
    _lex_col = 0
    _lex_line = 0
    _pyc_emit(OPMAP["RESUME"], 0, 0)
    _pyc_visit(root)
    return _pyc_assemble()
