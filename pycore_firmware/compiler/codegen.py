# Firmware T1–T5 codegen + assembler (compiler_design.md §5.5 / steps H, J, T4, T5).
# Recursive visit of nd_* (Rule 2) into ins words in opnd/ops, then
# _bi_code_alloc / blit / new. No CACHE. Constant folding (§11.3) rewrites
# int BinOp/UnaryOp and str Add in place before the visit. Jump args
# compensate for the hardware n_cache addend (POP_JUMP/JUMP_BACKWARD/
# FOR_ITER=1, JUMP_FORWARD=0).
#
# Instruction shapes follow CPython 3.14 / PyCPython codegen.py (PSF-2.0);
# rewritten over the SoA AST. Nested def is assembled depth-first into
# the parent's co_consts, then MAKE_FUNCTION. Freevars: COPY_FREE_VARS,
# LOAD_FAST of cell slots, BUILD_TUPLE, SET_FUNCTION_ATTRIBUTE 8.
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


def _pyc_fin_push(ks, nfinal, loop_depth):
    global _fin_n, _fin_ks, _fin_nf, _fin_loop
    # Write at _fin_n instead of always appending. A nested function saves
    # the lists and the counter, and a later push must not land past a hole
    # left by the nested compile.
    if len(_fin_ks) <= _fin_n:
        _fin_ks = _fin_ks + [0]
        _fin_nf = _fin_nf + [0]
        _fin_loop = _fin_loop + [0]
    _fin_ks[_fin_n] = ks
    _fin_nf[_fin_n] = nfinal
    _fin_loop[_fin_n] = loop_depth
    i = _fin_n
    _fin_n = _fin_n + 1
    return i


def _pyc_fin_pop():
    global _fin_n
    _fin_n = _fin_n - 1


def _pyc_fin_emit_one(i):
    # The inlined finally sits in the middle of the try body. Record it as a
    # hole so a raise inside the finally is not caught by this same try.
    global _hole_n, _hole_lo, _hole_hi, _hole_fin
    ks = _fin_ks[i]
    n = _fin_nf[i]
    lo = opnd_n
    j = 0
    while j < n:
        _pyc_visit(kids[ks + j])
        j = j + 1
    hi = opnd_n
    if lo == hi:
        return
    if len(_hole_lo) <= _hole_n:
        _hole_lo = _hole_lo + [0]
        _hole_hi = _hole_hi + [0]
        _hole_fin = _hole_fin + [0]
    _hole_lo[_hole_n] = lo
    _hole_hi[_hole_n] = hi
    _hole_fin[_hole_n] = i
    _hole_n = _hole_n + 1


def _pyc_fin_emit_all():
    global _fin_n
    i = _fin_n
    while i > 0:
        i = i - 1
        saved = _fin_n
        _fin_n = i
        _pyc_fin_emit_one(i)
        _fin_n = saved


def _pyc_fin_emit_from(min_loop):
    global _fin_n
    i = _fin_n
    while i > 0:
        i = i - 1
        if _fin_loop[i] < min_loop:
            break
        saved = _fin_n
        _fin_n = i
        _pyc_fin_emit_one(i)
        _fin_n = saved


def _pyc_clear_handler_name(hname):
    global _lex_col
    if hname == "":
        return
    none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
    _pyc_visit(none_id)
    name_id = _pyc_nd_new(ND["Name"], 1, 0, ND["Store"], 0, 0, hname)
    saved = _lex_col
    _lex_col = 1
    _pyc_visit(name_id)
    sid = _lex_i
    local = 0
    if (sc_kind[sid] & 255) == 1:
        names = sc_varnames[sid]
        nloc = sc_nlocals[sid]
        i = 0
        while i < nloc:
            if names[i] == hname:
                local = 1
                break
            i = i + 1
    if local:
        _lex_col = 2
        _pyc_visit(name_id)
    _lex_col = saved


def _pyc_global_index(name):
    global tk_n, tk_s
    i = 0
    while i < tk_n:
        if tk_s[i] == name:
            return i
        i = i + 1
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
    return ni


def _pyc_add_len():
    # Stack [..., obj, idx] -> [..., obj, len(obj) + idx].
    _pyc_emit(OPMAP["COPY"], 2, 0)
    ni = _pyc_global_index("len")
    _pyc_emit(OPMAP["LOAD_GLOBAL"], ni * 2 + 1, 0)
    _pyc_emit(OPMAP["SWAP"], 2, 0)
    _pyc_emit(OPMAP["SWAP"], 3, 0)
    _pyc_emit(OPMAP["CALL"], 1, 0)
    _pyc_emit(OPMAP["BINARY_OP"], 0, 0)


def _pyc_normalize_index():
    # Stack is [..., obj, idx]. A negative int becomes len(obj) + idx so the
    # hart never sees a negative subscript (deviation 3 / A4). Strings and
    # other keys are left alone: comparing them with 0 is a TYPE trap.
    global tk_a
    skip = _pyc_emit(0 - 1, 0, 0 - 1)
    _pyc_emit(OPMAP["COPY"], 1, 0)
    isi = _pyc_global_index("isinstance")
    _pyc_emit(OPMAP["LOAD_GLOBAL"], isi * 2 + 1, 0)
    _pyc_emit(OPMAP["SWAP"], 2, 0)
    _pyc_emit(OPMAP["SWAP"], 3, 0)
    ii = _pyc_global_index("int")
    _pyc_emit(OPMAP["LOAD_GLOBAL"], ii * 2, 0)
    _pyc_emit(OPMAP["CALL"], 2, 0)
    _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, skip)
    _pyc_emit(OPMAP["COPY"], 1, 0)
    _pyc_emit(OPMAP["LOAD_SMALL_INT"], 0, 0)
    _pyc_emit(OPMAP["COMPARE_OP"], 2, 0)
    _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, skip)
    _pyc_add_len()
    tk_a[skip] = opnd_n


def _pyc_maybe_normalize_index(idx_nid):
    # Constants are decided here. A non-negative int and every non-int
    # (dict keys) need no rewrite. A negative int always adds len().
    pair = _pyc_int_const(idx_nid)
    if pair[0] == 1:
        if pair[1] < 0:
            _pyc_add_len()
        return
    if nd_kind[idx_nid] == ND["Constant"]:
        return
    _pyc_normalize_index()


def _pyc_normalize_bound():
    # Stack [..., obj, bound]. None is an omitted slice end and stays None.
    # Any other value goes through the negative-index rewrite.
    skip = _pyc_emit(0 - 1, 0, 0 - 1)
    _pyc_emit(OPMAP["COPY"], 1, 0)
    _pyc_const_push(None)
    _pyc_emit(OPMAP["IS_OP"], 0, 0)
    _pyc_emit(OPMAP["POP_JUMP_IF_TRUE"], 0, skip)
    _pyc_normalize_index()
    tk_a[skip] = opnd_n


def _pyc_int_const(nid):
    if nid < 0:
        return [0, 0]
    if nd_kind[nid] != ND["Constant"]:
        return [0, 0]
    if nd_a[nid] != 0:
        return [0, 0]
    return [1, nd_obj[nid]]


def _pyc_clamp_slice(i, n):
    if i < 0:
        i = i + n
    if i < 0:
        i = 0
    if i > n:
        i = n
    return i


def _pyc_emit_display_slice(subj, slc):
    # BINARY_SLICE on a list or tuple is a TYPE trap. Evaluate every element
    # (side effects), keep the selected ones, and build a new display.
    global _lex_col
    n = nd_b[subj]
    ks = nd_a[subj]
    lo_n = nd_a[slc]
    hi_n = nd_b[slc]
    if lo_n < 0:
        lo = 0
    else:
        pair = _pyc_int_const(lo_n)
        if pair[0] == 0:
            _pyc_parse_error("slice of a list or tuple display is not supported")
        lo = _pyc_clamp_slice(pair[1], n)
    if hi_n < 0:
        hi = n
    else:
        pair = _pyc_int_const(hi_n)
        if pair[0] == 0:
            _pyc_parse_error("slice of a list or tuple display is not supported")
        hi = _pyc_clamp_slice(pair[1], n)
    count = 0
    i = 0
    while i < n:
        _lex_col = 0
        _pyc_visit(kids[ks + i])
        if lo < hi:
            if i >= lo:
                if i < hi:
                    count = count + 1
                else:
                    _pyc_emit(OPMAP["POP_TOP"], 0, 0)
            else:
                _pyc_emit(OPMAP["POP_TOP"], 0, 0)
        else:
            _pyc_emit(OPMAP["POP_TOP"], 0, 0)
        i = i + 1
    if nd_kind[subj] == ND["List"]:
        _pyc_emit(OPMAP["BUILD_LIST"], count, 0)
    else:
        _pyc_emit(OPMAP["BUILD_TUPLE"], count, 0)


def _pyc_exc_entry(start, end, target, depth, lasti):
    if start >= end:
        return
    _pyc_kids_append(start)
    _pyc_kids_append(end)
    _pyc_kids_append(target)
    _pyc_kids_append(depth)
    _pyc_kids_append(lasti)


def _pyc_exc_protect(start, end, fin_i, target, depth, lasti):
    # Cover [start, end) except finally bodies inlined into this try.
    n = 0
    los = [0] * 8
    his = [0] * 8
    i = 0
    while i < _hole_n:
        if _hole_fin[i] == fin_i:
            lo = _hole_lo[i]
            hi = _hole_hi[i]
            if lo < start:
                lo = start
            if hi > end:
                hi = end
            if lo < hi:
                if len(los) <= n:
                    los = los + ([0] * 8)
                    his = his + ([0] * 8)
                los[n] = lo
                his[n] = hi
                n = n + 1
        i = i + 1
    i = 1
    while i < n:
        lo = los[i]
        hi = his[i]
        j = i
        while j > 0:
            if los[j - 1] <= lo:
                break
            los[j] = los[j - 1]
            his[j] = his[j - 1]
            j = j - 1
        los[j] = lo
        his[j] = hi
        i = i + 1
    cursor = start
    i = 0
    while i < n:
        if los[i] > cursor:
            _pyc_exc_entry(cursor, los[i], target, depth, lasti)
        if his[i] > cursor:
            cursor = his[i]
        i = i + 1
    if cursor < end:
        _pyc_exc_entry(cursor, end, target, depth, lasti)


def _pyc_const_push(val):
    """Append ``val`` to the constant pool and emit LOAD_CONST for it.

    Identity pooling only, for the same reason the Constant visit uses it:
    ``==`` would COMPARE_OP a nested CODE_OBJECT against a later string on
    device (TYPE trap) and would fold 1000 onto 1000.0.
    """
    global stmts, stmt_n
    i = 0
    while i < stmt_n:
        if stmts[i] is val:
            _pyc_emit(OPMAP["LOAD_CONST"], i, 0)
            return
        i = i + 1
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


def _pyc_emit_comp(nid):
    # Comprehension is its own function. The iterator is evaluated here and
    # passed as the implicit argument ".0"; the target is a local of that
    # function, so it does not leak into the enclosing namespace.
    global opnd, ops, ops_obj, opnd_n, stmts, stmt_n, tk_s, tk_n, tk_a, tk_b
    global _lex_n, _lex_i, _lex_col, _lex_line, kids_n
    global _fin_n, _fin_ks, _fin_nf, _fin_loop
    global _hole_n, _hole_lo, _hole_hi, _hole_fin
    kind = nd_kind[nid]
    ks = nd_c[nid]
    _lex_col = 0
    _pyc_visit(kids[ks])
    _pyc_emit(OPMAP["GET_ITER"], 0, 0)
    sid = 0
    found = 0
    i = 0
    while i < sc_n:
        if sc_node[i] == nid:
            sid = i
            found = 1
            break
        i = i + 1
    if found == 0:
        _pyc_parse_error("comprehension scope missing")
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
    sv_fin_n = _fin_n
    sv_fin_ks = _fin_ks
    sv_fin_nf = _fin_nf
    sv_fin_loop = _fin_loop
    sv_hole_n = _hole_n
    sv_hole_lo = _hole_lo
    sv_hole_hi = _hole_hi
    sv_hole_fin = _hole_fin
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
    _fin_n = 0
    _fin_ks = [0] * 8
    _fin_nf = [0] * 8
    _fin_loop = [0] * 8
    _hole_n = 0
    _hole_lo = [0] * 8
    _hole_hi = [0] * 8
    _hole_fin = [0] * 8
    n_free = sc_kind[sid] >> 8
    if n_free > 0:
        _pyc_emit(OPMAP["COPY_FREE_VARS"], n_free, 0)
    n_fast = sc_nlocals[sid] - n_free
    ci = 0
    while ci < n_fast:
        cname = sc_varnames[sid][ci]
        is_cell = 0
        di = 0
        while di < sc_n:
            if di != sid:
                if (sc_kind[di] & 255) == 1:
                    p = sc_parent[di]
                    hit = 0
                    while p >= 0:
                        if p == sid:
                            hit = 1
                            break
                        p = sc_parent[p]
                    if hit:
                        nf = sc_kind[di] >> 8
                        nl = sc_nlocals[di]
                        j = nl - nf
                        while j < nl:
                            if sc_varnames[di][j] == cname:
                                is_cell = 1
                                break
                            j = j + 1
            if is_cell:
                break
            di = di + 1
        if is_cell:
            _pyc_emit(OPMAP["MAKE_CELL"], ci, 0)
        ci = ci + 1
    _pyc_emit(OPMAP["RESUME"], 0, 0)
    if kind == ND["ListComp"]:
        _pyc_emit(OPMAP["BUILD_LIST"], 0, 0)
    elif kind == ND["SetComp"]:
        _pyc_emit(OPMAP["BUILD_SET"], 0, 0)
    else:
        _pyc_emit(OPMAP["BUILD_MAP"], 0, 0)
    _pyc_emit(OPMAP["LOAD_FAST"], 0, 0)
    endfor = _pyc_emit(0 - 1, 0, 0 - 1)
    cont = _pyc_emit(0 - 1, 0, 0 - 1)
    tk_a[cont] = opnd_n
    _pyc_emit(OPMAP["FOR_ITER"], 0, endfor)
    _lex_col = 1
    _pyc_visit(nd_b[nid])
    _lex_col = 0
    cond = kids[ks + 1]
    skip = 0 - 1
    if cond >= 0:
        skip = _pyc_emit(0 - 1, 0, 0 - 1)
        _pyc_visit(cond)
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, skip)
    if kind == ND["DictComp"]:
        _pyc_visit(nd_a[nid])
        _pyc_visit(kids[ks + 2])
        _pyc_emit(OPMAP["MAP_ADD"], 2, 0)
    elif kind == ND["ListComp"]:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["LIST_APPEND"], 2, 0)
    else:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["SET_ADD"], 2, 0)
    if cond >= 0:
        tk_a[skip] = opnd_n
    _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
    tk_a[endfor] = opnd_n
    _pyc_emit(OPMAP["END_FOR"], 0, 0)
    _pyc_emit(OPMAP["POP_ITER"], 0, 0)
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
    _fin_n = sv_fin_n
    _fin_ks = sv_fin_ks
    _fin_nf = sv_fin_nf
    _fin_loop = sv_fin_loop
    _hole_n = sv_hole_n
    _hole_lo = sv_hole_lo
    _hole_hi = sv_hole_hi
    _hole_fin = sv_hole_fin
    n_free_c = sc_kind[sid] >> 8
    if n_free_c > 0:
        nloc_c = sc_nlocals[sid]
        fi = nloc_c - n_free_c
        while fi < nloc_c:
            fname = sc_varnames[sid][fi]
            pnames = sc_varnames[_lex_i]
            pn = sc_nlocals[_lex_i]
            pj = 0
            found = 0
            while pj < pn:
                if pnames[pj] == fname:
                    _pyc_emit(OPMAP["LOAD_FAST"], pj, 0)
                    found = 1
                    break
                pj = pj + 1
            if found == 0:
                _pyc_parse_error("freevar missing in enclosing scope")
            fi = fi + 1
        _pyc_emit(OPMAP["BUILD_TUPLE"], n_free_c, 0)
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
    if n_free_c > 0:
        _pyc_emit(OPMAP["SET_FUNCTION_ATTRIBUTE"], 8, 0)
    # [iter, func] -> [func, NULL, iter]
    _pyc_emit(OPMAP["SWAP"], 2, 0)
    _pyc_emit(OPMAP["PUSH_NULL"], 0, 0)
    _pyc_emit(OPMAP["SWAP"], 2, 0)
    _pyc_emit(OPMAP["CALL"], 1, 0)


def _pyc_visit(nid):
    global stmt_n, stmts, tk_n, tk_s, tk_a, tk_b, _lex_n, _lex_i, _lex_col
    global _lex_line, opnd, ops, ops_obj, opnd_n, kids_n
    global _fin_n, _fin_ks, _fin_nf, _fin_loop
    global _hole_n, _hole_lo, _hole_hi, _hole_fin
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
        ks = nd_a[nid]
        nt = nd_b[nid]
        _lex_col = 0
        _pyc_visit(nd_c[nid])
        i = 0
        while i < nt:
            if i + 1 < nt:
                _pyc_emit(OPMAP["COPY"], 1, 0)
            _lex_col = 1
            _pyc_visit(kids[ks + i])
            _lex_col = 0
            i = i + 1
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
        # Active finallies run inside-out, then the return value (still on
        # the stack; finally statements are net zero) is what we return.
        # A return inside one of those finallies hides that finally and
        # emits its own RETURN_VALUE, so this one becomes dead.
        _pyc_fin_emit_all()
        _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        return
    if kind == ND["Global"]:
        return
    if kind == ND["FunctionDef"] or kind == ND["Lambda"]:
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
        sv_fin_n = _fin_n
        sv_fin_ks = _fin_ks
        sv_fin_nf = _fin_nf
        sv_fin_loop = _fin_loop
        sv_hole_n = _hole_n
        sv_hole_lo = _hole_lo
        sv_hole_hi = _hole_hi
        sv_hole_fin = _hole_fin
        is_lam = 0
        if kind == ND["Lambda"]:
            is_lam = 1
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
        _fin_n = 0
        _fin_ks = [0] * 8
        _fin_nf = [0] * 8
        _fin_loop = [0] * 8
        _hole_n = 0
        _hole_lo = [0] * 8
        _hole_hi = [0] * 8
        _hole_fin = [0] * 8
        n_free = sc_kind[sid] >> 8
        if n_free > 0:
            _pyc_emit(OPMAP["COPY_FREE_VARS"], n_free, 0)
        n_fast = sc_nlocals[sid] - n_free
        ci = 0
        while ci < n_fast:
            cname = sc_varnames[sid][ci]
            is_cell = 0
            di = 0
            while di < sc_n:
                if di != sid:
                    if (sc_kind[di] & 255) == 1:
                        p = sc_parent[di]
                        hit = 0
                        while p >= 0:
                            if p == sid:
                                hit = 1
                                break
                            p = sc_parent[p]
                        if hit:
                            nf = sc_kind[di] >> 8
                            nl = sc_nlocals[di]
                            j = nl - nf
                            while j < nl:
                                if sc_varnames[di][j] == cname:
                                    is_cell = 1
                                    break
                                j = j + 1
                if is_cell:
                    break
                di = di + 1
            if is_cell:
                _pyc_emit(OPMAP["MAKE_CELL"], ci, 0)
            ci = ci + 1
        _pyc_emit(OPMAP["RESUME"], 0, 0)
        ks = nd_a[nid]
        nargs = nd_b[nid] & 65535
        ndec = (nd_b[nid] >> 16) & 65535
        nbody = nd_c[nid]
        if is_lam:
            _pyc_visit(kids[ks + ndec + nargs])
            _pyc_emit(OPMAP["RETURN_VALUE"], 0, 0)
        else:
            i = 0
            while i < nbody:
                _pyc_visit(kids[ks + ndec + nargs + i])
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
        _fin_n = sv_fin_n
        _fin_ks = sv_fin_ks
        _fin_nf = sv_fin_nf
        _fin_loop = sv_fin_loop
        _hole_n = sv_hole_n
        _hole_lo = sv_hole_lo
        _hole_hi = sv_hole_hi
        _hole_fin = sv_hole_fin
        di = 0
        while di < ndec:
            _pyc_visit(kids[ks + di])
            di = di + 1
        cap = len(stmts)
        while cap < stmt_n + 1:
            extra = cap
            if extra < 8:
                extra = 8
            stmts = stmts + ([0] * extra)
            cap = len(stmts)
        stmts[stmt_n] = child
        n_free_c = sc_kind[sid] >> 8
        if n_free_c > 0:
            nloc_c = sc_nlocals[sid]
            fi = nloc_c - n_free_c
            while fi < nloc_c:
                fname = sc_varnames[sid][fi]
                pnames = sc_varnames[_lex_i]
                pn = sc_nlocals[_lex_i]
                pj = 0
                found = 0
                while pj < pn:
                    if pnames[pj] == fname:
                        _pyc_emit(OPMAP["LOAD_FAST"], pj, 0)
                        found = 1
                        break
                    pj = pj + 1
                if found == 0:
                    _pyc_parse_error("freevar missing in enclosing scope")
                fi = fi + 1
            _pyc_emit(OPMAP["BUILD_TUPLE"], n_free_c, 0)
        _pyc_emit(OPMAP["LOAD_CONST"], stmt_n, 0)
        stmt_n = stmt_n + 1
        _pyc_emit(OPMAP["MAKE_FUNCTION"], 0, 0)
        if n_free_c > 0:
            _pyc_emit(OPMAP["SET_FUNCTION_ATTRIBUTE"], 8, 0)
        i = 0
        while i < ndec:
            _pyc_emit(OPMAP["CALL"], 0, 0)
            i = i + 1
        if is_lam == 0:
            name_id = _pyc_nd_new(
                ND["Name"], 1, 0, ND["Store"], 0, 0, nd_obj[nid][0]
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
        _pyc_const_push(val)
        return
    if kind == ND["Name"]:
        name = nd_obj[nid]
        sid = _lex_i
        local = 0
        idx = 0
        if (sc_kind[sid] & 255) == 1:
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
            n_free = sc_kind[sid] >> 8
            n_fast = sc_nlocals[sid] - n_free
            deref = 0
            if idx >= n_fast:
                deref = 1
            else:
                di = 0
                while di < sc_n:
                    if di != sid:
                        if (sc_kind[di] & 255) == 1:
                            p = sc_parent[di]
                            hit = 0
                            while p >= 0:
                                if p == sid:
                                    hit = 1
                                    break
                                p = sc_parent[p]
                            if hit:
                                nf = sc_kind[di] >> 8
                                nl = sc_nlocals[di]
                                j = nl - nf
                                while j < nl:
                                    if sc_varnames[di][j] == name:
                                        deref = 1
                                        break
                                    j = j + 1
                    if deref:
                        break
                    di = di + 1
            if deref:
                if store == 1:
                    _pyc_emit(OPMAP["STORE_DEREF"], idx, 0)
                elif store == 2:
                    _pyc_parse_error("cannot delete closed-over name")
                else:
                    _pyc_emit(OPMAP["LOAD_DEREF"], idx, 0)
            else:
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
        if (sc_kind[sid] & 255) == 1:
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
        n = nd_c[nid] & 65535
        nkw = nd_c[nid] >> 16
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
        if nkw == 0:
            _pyc_emit(OPMAP["CALL"], n, 0)
            return
        # CPython 3.14: the keyword names ride in co_consts as a tuple and
        # CALL_KW's oparg is the *total* argument count, positional included.
        kwnames = nd_obj[nid]
        kwt = ()
        i = 0
        while i < nkw:
            kwt = kwt + (kwnames[i],)
            i = i + 1
        _pyc_const_push(kwt)
        _pyc_emit(OPMAP["CALL_KW"], n, 0)
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
            subj = nd_a[nid]
            if nd_kind[subj] == ND["List"] or nd_kind[subj] == ND["Tuple"]:
                _pyc_emit_display_slice(subj, slc)
                return
            _pyc_visit(subj)
            lo = nd_a[slc]
            hi = nd_b[slc]
            if lo < 0:
                none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
                _pyc_visit(none_id)
            else:
                _pyc_visit(lo)
                _pyc_normalize_bound()
            if hi < 0:
                none_id = _pyc_nd_new(ND["Constant"], 1, 0, 5, 0, 0, None)
                _pyc_visit(none_id)
            else:
                _pyc_visit(hi)
                # [obj, lo, hi] -> normalize hi against obj, which sits under lo.
                _pyc_emit(OPMAP["COPY"], 3, 0)
                _pyc_emit(OPMAP["SWAP"], 2, 0)
                _pyc_normalize_bound()
                _pyc_emit(OPMAP["SWAP"], 2, 0)
                _pyc_emit(OPMAP["POP_TOP"], 0, 0)
            _pyc_emit(OPMAP["BINARY_SLICE"], 0, 0)
            return
        if store == 1:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _pyc_maybe_normalize_index(nd_b[nid])
            _lex_col = 1
            _pyc_emit(OPMAP["STORE_SUBSCR"], 0, 0)
            return
        if store == 2:
            _lex_col = 0
            _pyc_visit(nd_a[nid])
            _pyc_visit(nd_b[nid])
            _pyc_maybe_normalize_index(nd_b[nid])
            _lex_col = 2
            _pyc_emit(OPMAP["DELETE_SUBSCR"], 0, 0)
            return
        _pyc_visit(nd_a[nid])
        _pyc_visit(nd_b[nid])
        _pyc_maybe_normalize_index(nd_b[nid])
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
        _pyc_fin_emit_from(_lex_line)
        br = tk_b[_lex_line * 2]
        _pyc_emit(OPMAP["JUMP_FORWARD"], 0, br)
        return
    if kind == ND["Continue"]:
        if _lex_line < 1:
            _pyc_parse_error("'continue' not properly in loop")
        _pyc_fin_emit_from(_lex_line)
        cont = tk_b[_lex_line * 2 + 1]
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        return
    if kind == ND["IfExp"]:
        # body if test else orelse -- same jump shape as the If statement,
        # but every arm leaves exactly one value on the stack.
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        else_lab = _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, 0 - 1)
        _pyc_visit(nd_b[nid])
        end_lab = _pyc_emit(OPMAP["JUMP_FORWARD"], 0, 0 - 1)
        tk_a[else_lab] = opnd_n
        _pyc_visit(nd_c[nid])
        tk_a[end_lab] = opnd_n
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
        norelse = nd_obj[nid]
        else_lab = br
        if norelse:
            else_lab = _pyc_emit(0 - 1, 0, 0 - 1)
        _lex_line = _lex_line + 1
        if len(tk_b) < _lex_line * 2 + 2:
            tk_b = tk_b + ([0] * 8)
        tk_b[_lex_line * 2] = br
        tk_b[_lex_line * 2 + 1] = cont
        tk_a[cont] = opnd_n
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, else_lab)
        ks = nd_b[nid]
        nbody = nd_c[nid]
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        tk_a[else_lab] = opnd_n
        _lex_line = _lex_line - 1
        if norelse:
            i = 0
            while i < norelse:
                _pyc_visit(kids[ks + nbody + i])
                i = i + 1
            tk_a[br] = opnd_n
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
        packed = nd_obj[nid]
        nbody = packed & 65535
        norelse = packed >> 16
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["JUMP_BACKWARD"], 0, cont)
        tk_a[endfor] = opnd_n
        _pyc_emit(OPMAP["END_FOR"], 0, 0)
        _lex_line = _lex_line - 1
        if norelse:
            i = 0
            while i < norelse:
                _pyc_visit(kids[ks + nbody + i])
                i = i + 1
        tk_a[popiter] = opnd_n
        _pyc_emit(OPMAP["POP_ITER"], 0, 0)
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
        _pyc_emit_comp(nid)
        return
    if kind == ND["Try"]:
        nbody = nd_b[nid]
        nh = nd_c[nid]
        norelse = nd_obj[nid] & 65535
        nfinal = nd_obj[nid] >> 16
        ks = nd_a[nid]
        fbase = ks + nbody + nh + norelse
        fin_i = 0 - 1
        if nfinal > 0:
            fin_i = _pyc_fin_push(fbase, nfinal, _lex_line)
        orelse_lab = _pyc_emit(0 - 1, 0, 0 - 1)
        finally_lab = _pyc_emit(0 - 1, 0, 0 - 1)
        try_start = opnd_n
        i = 0
        while i < nbody:
            _pyc_visit(kids[ks + i])
            i = i + 1
        try_end = opnd_n
        _pyc_emit(OPMAP["JUMP_FORWARD"], 0, orelse_lab)
        if nfinal > 0:
            _pyc_fin_pop()
        handler = opnd_n
        _pyc_emit(OPMAP["PUSH_EXC_INFO"], 0, 0)
        if nh < 1:
            i = 0
            while i < nfinal:
                _pyc_visit(kids[fbase + i])
                i = i + 1
            _pyc_emit(OPMAP["RERAISE"], 0, 0)
        else:
            hi = 0
            while hi < nh:
                h = kids[ks + nbody + hi]
                typ = nd_a[h]
                miss = 0
                _lex_col = 0
                if typ >= 0:
                    _pyc_visit(typ)
                    _pyc_emit(OPMAP["CHECK_EXC_MATCH"], 0, 0)
                    miss = _pyc_emit(OPMAP["POP_JUMP_IF_FALSE"], 0, 0 - 1)
                hname = nd_obj[h]
                # Bare except uses ""; a name is a str. Mixed-tag != TYPE-traps.
                if hname == "":
                    _pyc_emit(OPMAP["POP_TOP"], 0, 0)
                else:
                    name_id = _pyc_nd_new(
                        ND["Name"], 1, 0, ND["Store"], 0, 0, hname
                    )
                    _lex_col = 1
                    _pyc_visit(name_id)
                    _lex_col = 0
                hks = nd_b[h]
                hn = nd_c[h]
                body_start = opnd_n
                j = 0
                while j < hn:
                    _pyc_visit(kids[hks + j])
                    j = j + 1
                body_end = opnd_n
                _pyc_emit(OPMAP["POP_EXCEPT"], 0, 0)
                _pyc_clear_handler_name(hname)
                # else-clause stays on the no-exception path only.
                _pyc_emit(OPMAP["JUMP_FORWARD"], 0, finally_lab)
                if hname != "":
                    name_cu = opnd_n
                    _pyc_clear_handler_name(hname)
                    _pyc_emit(OPMAP["RERAISE"], 1, 0)
                    _pyc_exc_entry(body_start, body_end, name_cu, 1, 1)
                if typ >= 0:
                    tk_a[miss] = opnd_n
                hi = hi + 1
            _pyc_emit(OPMAP["RERAISE"], 0, 0)
        cleanup = opnd_n
        _pyc_emit(OPMAP["COPY"], 3, 0)
        _pyc_emit(OPMAP["POP_EXCEPT"], 0, 0)
        _pyc_emit(OPMAP["RERAISE"], 1, 0)
        cleanup_end = opnd_n
        finally_h = 0
        finally_c = 0
        if nh > 0:
            if nfinal > 0:
                finally_h = opnd_n
                _pyc_emit(OPMAP["PUSH_EXC_INFO"], 0, 0)
                i = 0
                while i < nfinal:
                    _pyc_visit(kids[fbase + i])
                    i = i + 1
                _pyc_emit(OPMAP["RERAISE"], 0, 0)
                finally_c = opnd_n
                _pyc_emit(OPMAP["COPY"], 3, 0)
                _pyc_emit(OPMAP["POP_EXCEPT"], 0, 0)
                _pyc_emit(OPMAP["RERAISE"], 1, 0)
        tk_a[orelse_lab] = opnd_n
        i = 0
        while i < norelse:
            _pyc_visit(kids[ks + nbody + nh + i])
            i = i + 1
        tk_a[finally_lab] = opnd_n
        i = 0
        while i < nfinal:
            _pyc_visit(kids[fbase + i])
            i = i + 1
        _pyc_exc_protect(try_start, try_end, fin_i, handler, 0, 0)
        _pyc_exc_entry(handler, cleanup, cleanup, 1, 1)
        if nh > 0:
            if nfinal > 0:
                _pyc_exc_entry(cleanup, cleanup_end, finally_h, 0, 0)
                _pyc_exc_entry(finally_h, finally_c, finally_c, 1, 1)
        return
    if kind == ND["JoinedStr"]:
        n = nd_b[nid]
        ks = nd_a[nid]
        if n == 0:
            val = ""
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
            return
        if n == 1:
            kid = kids[ks]
            if nd_kind[kid] == ND["Constant"]:
                _pyc_visit(kid)
                return
            _pyc_visit(kid)
            return
        i = 0
        while i < n:
            _pyc_visit(kids[ks + i])
            i = i + 1
        _pyc_emit(OPMAP["BUILD_STRING"], n, 0)
        return
    if kind == ND["FormattedValue"]:
        _pyc_visit(nd_a[nid])
        conv = nd_b[nid]
        if conv == 115:
            _pyc_emit(OPMAP["CONVERT_VALUE"], 1, 0)
        elif conv == 114:
            _pyc_emit(OPMAP["CONVERT_VALUE"], 2, 0)
        elif conv == 97:
            _pyc_emit(OPMAP["CONVERT_VALUE"], 3, 0)
        _pyc_emit(OPMAP["FORMAT_SIMPLE"], 0, 0)
        return
    if kind == ND["Assert"]:
        _pyc_visit(nd_a[nid])
        _pyc_emit(OPMAP["TO_BOOL"], 0, 0)
        end_lab = _pyc_emit(OPMAP["POP_JUMP_IF_TRUE"], 0, 0 - 1)
        name_id = _pyc_nd_new(
            ND["Name"], 1, 0, ND["Load"], 0, 0, "AssertionError"
        )
        _lex_col = 0
        _pyc_visit(name_id)
        msg = nd_b[nid]
        if msg >= 0:
            _pyc_visit(msg)
            _pyc_emit(OPMAP["CALL"], 0, 0)
        _pyc_emit(OPMAP["RAISE_VARARGS"], 1, 0)
        tk_a[end_lab] = opnd_n
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
                delta = tgt - i - 1 - nc
            else:
                delta = i + 1 + nc - tgt
            if delta < 0:
                # Hardware adds n_cache to every taken branch, so a
                # conditional jump cannot name its own fall-through. Empty
                # suite ("if c: pass") puts the label at i+1; the branch is
                # dead and only the pop survives. Else _bi_code_blit
                # TYPE-traps a negative oparg (A4).
                if delta != 0 - 1:
                    _pyc_parse_error("internal: negative jump offset")
                if op == OPMAP["POP_JUMP_IF_FALSE"] or op == OPMAP["POP_JUMP_IF_TRUE"]:
                    opnd[i] = OPMAP["POP_TOP"]
                    delta = 0
                else:
                    _pyc_parse_error("internal: negative jump offset")
            ops[i] = delta
        i = i + 1
    depth = 0
    maxd = 0
    i = 0
    while i < opnd_n:
        op = opnd[i]
        arg = ops[i]
        d = 0
        if op == OPMAP["LOAD_GLOBAL"]:
            d = 1
            if arg & 1:
                d = 2
        elif (
            op == OPMAP["LOAD_SMALL_INT"]
            or op == OPMAP["LOAD_CONST"]
            or op == OPMAP["LOAD_NAME"]
            or op == OPMAP["LOAD_FAST"]
            or op == OPMAP["LOAD_DEREF"]
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
            or op == OPMAP["STORE_DEREF"]
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
        elif op == OPMAP["SET_FUNCTION_ATTRIBUTE"]:
            d = 0 - 1
        elif op == OPMAP["CALL"]:
            d = 0 - (arg + 1)
        elif op == OPMAP["CALL_KW"]:
            # [callable, self/NULL, arg0..argN-1, kwnames] -> [result]
            d = 0 - (arg + 2)
        elif (
            op == OPMAP["BUILD_LIST"]
            or op == OPMAP["BUILD_TUPLE"]
            or op == OPMAP["BUILD_SET"]
            or op == OPMAP["BUILD_STRING"]
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
    meta = (
        (sc_kwonly[_lex_i] << 48)
        | (maxd << 32)
        | (nloc << 16)
        | sc_argcount[_lex_i]
    )
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
    # Defaults live on the code object, not on a function object: PyCore
    # implements SET_FUNCTION_ATTRIBUTE 8 (closure) only, so CPython's
    # flags 1/2 have no encoding (compiler_design.md D10).
    dl = sc_defaults[_lex_i]
    dflt = ()
    i = 0
    while i < len(dl):
        dflt = dflt + (dl[i],)
        i = i + 1
    return _bi_code_new(
        [
            base,
            consts,
            names,
            meta,
            dflt,
            varnames,
            sc_kwdefaults[_lex_i],
            exctable,
            sc_flags[_lex_i],
        ]
    )


def _pyc_codegen_main():
    global opnd_n, opnd, ops, ops_obj, stmt_n, stmts, tk_n, tk_s, tk_a, tk_b
    global _lex_n, _lex_i, _lex_col, _lex_line
    global _fin_n, _fin_ks, _fin_nf, _fin_loop
    global _hole_n, _hole_lo, _hole_hi, _hole_fin
    _pyc_lex(_in_src)
    root = _pyc_parse(_in_mode)
    _pyc_symtab(root)
    # §11.3 constant folding: bottom-up rewrite of Constant BinOp / UnaryOp.
    # Int + - * & | ^ and unary - ~ ; str Add. Skip / // % ** << >> (div0,
    # float, shift/pow overflow). Nested if only — no extra _PYC_G helper.
    folded = 1
    while folded:
        folded = 0
        i = 0
        while i < nd_n:
            k = nd_kind[i]
            if k == ND["BinOp"]:
                L = nd_a[i]
                R = nd_c[i]
                if nd_kind[L] == ND["Constant"]:
                    if nd_kind[R] == ND["Constant"]:
                        opk = nd_b[i]
                        ok = 0
                        res = 0
                        tag = 0
                        if nd_a[L] == 0:
                            if nd_a[R] == 0:
                                lv = nd_obj[L]
                                rv = nd_obj[R]
                                if opk == ND["Add"]:
                                    res = lv + rv
                                    ok = 1
                                elif opk == ND["Sub"]:
                                    res = lv - rv
                                    ok = 1
                                elif opk == ND["Mult"]:
                                    res = lv * rv
                                    ok = 1
                                elif opk == ND["BitAnd"]:
                                    res = lv & rv
                                    ok = 1
                                elif opk == ND["BitOr"]:
                                    res = lv | rv
                                    ok = 1
                                elif opk == ND["BitXor"]:
                                    res = lv ^ rv
                                    ok = 1
                                tag = 0
                        if ok == 0:
                            if nd_a[L] == 2:
                                if nd_a[R] == 2:
                                    if opk == ND["Add"]:
                                        res = nd_obj[L] + nd_obj[R]
                                        ok = 1
                                        tag = 2
                        if ok:
                            nd_kind[i] = ND["Constant"]
                            nd_a[i] = tag
                            nd_b[i] = 0
                            nd_c[i] = 0
                            nd_obj[i] = res
                            folded = 1
            elif k == ND["UnaryOp"]:
                kid = nd_b[i]
                if nd_kind[kid] == ND["Constant"]:
                    u = nd_a[i]
                    if u == ND["UAdd"]:
                        nd_kind[i] = ND["Constant"]
                        nd_a[i] = nd_a[kid]
                        nd_b[i] = 0
                        nd_c[i] = 0
                        nd_obj[i] = nd_obj[kid]
                        folded = 1
                    elif nd_a[kid] == 0:
                        lv = nd_obj[kid]
                        ok = 0
                        res = 0
                        if u == ND["USub"]:
                            res = -lv
                            ok = 1
                        elif u == ND["Invert"]:
                            res = ~lv
                            ok = 1
                        if ok:
                            nd_kind[i] = ND["Constant"]
                            nd_a[i] = 0
                            nd_b[i] = 0
                            nd_c[i] = 0
                            nd_obj[i] = res
                            folded = 1
            i = i + 1
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
    _fin_n = 0
    _fin_ks = [0] * 8
    _fin_nf = [0] * 8
    _fin_loop = [0] * 8
    _hole_n = 0
    _hole_lo = [0] * 8
    _hole_hi = [0] * 8
    _hole_fin = [0] * 8
    _pyc_emit(OPMAP["RESUME"], 0, 0)
    _pyc_visit(root)
    return _pyc_assemble()
