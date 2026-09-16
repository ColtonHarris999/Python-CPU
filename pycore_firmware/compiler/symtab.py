# Firmware symbol table (compiler_design.md §5.5 / step G).
# Iterative walk of nd_* / kids into per-scope locals. Scope rules follow
# CPython / PyCPython (module + function, `global`); closures are computed
# only so we can raise, never so we can emit MAKE_CELL.
#
# Scope 0 is the Module / Expression: every name is global (not FAST).
# Function scope: parameters and STORE targets are locals unless `global`.
# A load of an enclosing function local is
# SyntaxError("closures are not supported on this target").
# nlocals > 240 (RF_WINDOW_CAP, §6.1 S-6) is a SyntaxError; stacksize is H.


def _pyc_sy_work_push(nid, phase):
    global opnd, opnd_n, ops
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
        cap = len(ops)
    opnd[opnd_n] = nid
    ops[opnd_n] = phase
    opnd_n = opnd_n + 1


def _pyc_sy_new_scope(kind, parent, nid):
    global sc_n, sc_kind, sc_parent, sc_node, sc_nlocals, sc_argcount
    global sc_varnames
    cap = len(sc_kind)
    while cap < sc_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        sc_kind = sc_kind + ([0] * extra)
        sc_parent = sc_parent + ([0] * extra)
        sc_node = sc_node + ([0] * extra)
        sc_nlocals = sc_nlocals + ([0] * extra)
        sc_argcount = sc_argcount + ([0] * extra)
        sc_varnames = sc_varnames + ([0] * extra)
        cap = len(sc_kind)
    sid = sc_n
    sc_kind[sid] = kind
    sc_parent[sid] = parent
    sc_node[sid] = nid
    sc_nlocals[sid] = 0
    sc_argcount[sid] = 0
    sc_varnames[sid] = [0] * 8
    sc_n = sc_n + 1
    return sid


def _pyc_sy_names_has(xs, n, name):
    i = 0
    while i < n:
        if xs[i] == name:
            return 1
        i = i + 1
    return 0


def _pyc_sy_names_add(xs, n, name):
    if _pyc_sy_names_has(xs, n, name):
        return xs, n
    cap = len(xs)
    while cap < n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        xs = xs + ([0] * extra)
        cap = len(xs)
    xs[n] = name
    return xs, n + 1


def _pyc_sy_push_children(nid):
    kind = nd_kind[nid]
    a = nd_a[nid]
    b = nd_b[nid]
    c = nd_c[nid]
    if kind == ND["Module"]:
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["Expression"] or kind == ND["Expr"]:
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Assign"]:
        _pyc_sy_work_push(c, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Return"]:
        if a >= 0:
            _pyc_sy_work_push(a, 0)
        return
    if kind == ND["BinOp"]:
        _pyc_sy_work_push(c, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["UnaryOp"]:
        _pyc_sy_work_push(b, 0)
        return
    if kind == ND["BoolOp"]:
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        return
    if kind == ND["Compare"]:
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Call"]:
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Attribute"]:
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Subscript"]:
        _pyc_sy_work_push(b, 0)
        _pyc_sy_work_push(a, 0)
        return
    if (
        kind == ND["Name"]
        or kind == ND["Constant"]
        or kind == ND["Global"]
        or kind == ND["FunctionDef"]
    ):
        return
    _pyc_parse_error("unsupported node in symbol table")


def _pyc_symtab(root):
    global sc_n, sc_kind, sc_parent, sc_node, sc_nlocals, sc_argcount
    global sc_varnames, opnd, opnd_n, ops, stmts, stmt_n
    cap = nd_n
    if cap < 8:
        cap = 8
    sc_kind = [0] * cap
    sc_parent = [0] * cap
    sc_node = [0] * cap
    sc_nlocals = [0] * cap
    sc_argcount = [0] * cap
    sc_varnames = [0] * cap
    sc_n = 0
    gdecl = [0] * cap
    gdecl_n = [0] * cap
    uses = [0] * cap
    uses_n = [0] * cap
    opnd_n = 0
    stmts = [0] * 8
    stmt_n = 0
    sid0 = _pyc_sy_new_scope(0, 0 - 1, root)
    gdecl[sid0] = [0] * 8
    gdecl_n[sid0] = 0
    uses[sid0] = [0] * 8
    uses_n[sid0] = 0
    stmts[0] = sid0
    stmt_n = 1
    _pyc_sy_work_push(root, 0)
    load_k = ND["Load"]
    store_k = ND["Store"]
    fn_k = ND["FunctionDef"]
    name_k = ND["Name"]
    glob_k = ND["Global"]
    while opnd_n > 0:
        opnd_n = opnd_n - 1
        nid = opnd[opnd_n]
        phase = ops[opnd_n]
        kind = nd_kind[nid]
        cur = stmts[stmt_n - 1]
        if phase == 1:
            if kind != fn_k:
                continue
            nloc = sc_nlocals[cur]
            if nloc > 240:
                _pyc_parse_error("too many locals")
            i = 0
            un = uses_n[cur]
            while i < un:
                name = uses[cur][i]
                if _pyc_sy_names_has(sc_varnames[cur], nloc, name):
                    i = i + 1
                    continue
                if _pyc_sy_names_has(gdecl[cur], gdecl_n[cur], name):
                    i = i + 1
                    continue
                p = sc_parent[cur]
                while p >= 0:
                    if sc_kind[p] == 1:
                        if _pyc_sy_names_has(
                            sc_varnames[p], sc_nlocals[p], name
                        ):
                            if _pyc_sy_names_has(
                                gdecl[p], gdecl_n[p], name
                            ) == 0:
                                _pyc_parse_error(
                                    "closures are not supported on this target"
                                )
                    p = sc_parent[p]
                i = i + 1
            stmt_n = stmt_n - 1
            continue
        if kind == fn_k:
            fname = nd_obj[nid]
            if sc_kind[cur] == 1:
                names, n = _pyc_sy_names_add(
                    sc_varnames[cur], sc_nlocals[cur], fname
                )
                sc_varnames[cur] = names
                sc_nlocals[cur] = n
            sid = _pyc_sy_new_scope(1, cur, nid)
            gdecl[sid] = [0] * 8
            gdecl_n[sid] = 0
            uses[sid] = [0] * 8
            uses_n[sid] = 0
            nargs = nd_b[nid]
            nbody = nd_c[nid]
            ks = nd_a[nid]
            sc_argcount[sid] = nargs
            j = 0
            while j < nargs:
                arg_nid = kids[ks + j]
                names, n = _pyc_sy_names_add(
                    sc_varnames[sid], sc_nlocals[sid], nd_obj[arg_nid]
                )
                sc_varnames[sid] = names
                sc_nlocals[sid] = n
                j = j + 1
            cap = len(stmts)
            while cap < stmt_n + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                stmts = stmts + ([0] * extra)
                cap = len(stmts)
            stmts[stmt_n] = sid
            stmt_n = stmt_n + 1
            _pyc_sy_work_push(nid, 1)
            j = nbody
            while j > 0:
                j = j - 1
                _pyc_sy_work_push(kids[ks + nargs + j], 0)
            continue
        if kind == name_k:
            name = nd_obj[nid]
            ctx = nd_a[nid]
            if ctx == store_k:
                if _pyc_sy_names_has(gdecl[cur], gdecl_n[cur], name) == 0:
                    if sc_kind[cur] == 1:
                        names, n = _pyc_sy_names_add(
                            sc_varnames[cur], sc_nlocals[cur], name
                        )
                        sc_varnames[cur] = names
                        sc_nlocals[cur] = n
            else:
                if ctx == load_k:
                    xs, n = _pyc_sy_names_add(uses[cur], uses_n[cur], name)
                    uses[cur] = xs
                    uses_n[cur] = n
            continue
        if kind == glob_k:
            names = nd_obj[nid]
            nn = nd_a[nid]
            i = 0
            while i < nn:
                name = names[i]
                if _pyc_sy_names_has(
                    sc_varnames[cur], sc_nlocals[cur], name
                ):
                    _pyc_parse_error(
                        "name '" + name + "' is assigned to before global declaration"
                    )
                if _pyc_sy_names_has(uses[cur], uses_n[cur], name):
                    _pyc_parse_error(
                        "name '" + name + "' is used prior to global declaration"
                    )
                xs, n = _pyc_sy_names_add(gdecl[cur], gdecl_n[cur], name)
                gdecl[cur] = xs
                gdecl_n[cur] = n
                i = i + 1
            continue
        _pyc_sy_push_children(nid)
    return sc_n


def _pyc_symtab_checksum():
    cs = sc_n
    i = 0
    while i < sc_n:
        cs = cs * 131 + sc_kind[i]
        cs = cs * 131 + (sc_parent[i] + 1)
        cs = cs * 131 + sc_nlocals[i]
        cs = cs * 131 + sc_argcount[i]
        names = sc_varnames[i]
        nloc = sc_nlocals[i]
        j = 0
        while j < nloc:
            s = names[j]
            k = 0
            n = len(s)
            cs = cs * 131 + n
            while k < n:
                cs = cs * 131 + ord(s[k])
                k = k + 1
            j = j + 1
        if cs < 0:
            cs = 0 - cs
        cs = cs & 2147483647
        i = i + 1
    return cs


def _pyc_symtab_main():
    _pyc_lex(_in_src)
    root = _pyc_parse(_in_mode)
    _pyc_symtab(root)
    return _pyc_symtab_checksum()
