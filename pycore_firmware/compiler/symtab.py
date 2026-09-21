# Firmware symbol table (compiler_design.md §5.5 / step G / §11.4).
# Iterative walk of nd_* / kids into per-scope locals. Scope rules follow
# CPython / PyCPython (module + function, `global`). Closures: a load of an
# enclosing function local is a freevar of the nested scope (and of every
# intervening function) and a cellvar of the definer. Freevars are appended
# onto sc_varnames; sc_nlocals is nlocalsplus; sc_kind = 1 | (n_free << 8).
# Cellvars stay in-place among the original locals (MAKE_CELL wraps that slot).
# Parameter metadata rides on the scope, not the node: sc_argcount is
# co_argcount (positional only), sc_kwonly is co_kwonlyargcount, sc_flags is
# has_varargs | (has_varkw << 1), and sc_defaults / sc_kwdefaults are the
# literal default values the assembler hands to _bi_code_new fields 4 and 6.
#
# Scope 0 is the Module / Expression: every name is global (not FAST).
# Function scope: parameters and STORE targets are locals unless `global`.
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
    global sc_varnames, sc_kwonly, sc_flags, sc_defaults, sc_kwdefaults
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
        sc_kwonly = sc_kwonly + ([0] * extra)
        sc_flags = sc_flags + ([0] * extra)
        sc_defaults = sc_defaults + ([0] * extra)
        sc_kwdefaults = sc_kwdefaults + ([0] * extra)
        cap = len(sc_kind)
    sid = sc_n
    sc_kind[sid] = kind
    sc_parent[sid] = parent
    sc_node[sid] = nid
    sc_nlocals[sid] = 0
    sc_argcount[sid] = 0
    sc_varnames[sid] = [0] * 8
    sc_kwonly[sid] = 0
    sc_flags[sid] = 0
    sc_defaults[sid] = []
    sc_kwdefaults[sid] = {}
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
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
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
        i = c & 65535
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
    if kind == ND["IfExp"]:
        _pyc_sy_work_push(c, 0)
        _pyc_sy_work_push(b, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["If"]:
        i = nd_obj[nid]
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + c + i], 0)
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["While"]:
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["For"]:
        nbody = nd_obj[nid]
        i = nbody
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[c + i], 0)
        _pyc_sy_work_push(b, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["AugAssign"]:
        _pyc_sy_work_push(c, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Delete"]:
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["List"] or kind == ND["Tuple"] or kind == ND["Set"]:
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["Dict"]:
        n = b * 2
        i = n
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["Slice"]:
        if c >= 0:
            _pyc_sy_work_push(c, 0)
        if b >= 0:
            _pyc_sy_work_push(b, 0)
        if a >= 0:
            _pyc_sy_work_push(a, 0)
        return
    if (
        kind == ND["ListComp"]
        or kind == ND["SetComp"]
        or kind == ND["DictComp"]
    ):
        # c is a kids index: [iter, cond] (+[value] for a DictComp).
        if kind == ND["DictComp"]:
            _pyc_sy_work_push(kids[c + 2], 0)
        if kids[c + 1] >= 0:
            _pyc_sy_work_push(kids[c + 1], 0)
        _pyc_sy_work_push(kids[c], 0)
        _pyc_sy_work_push(b, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Raise"]:
        if a >= 0:
            _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Assert"]:
        if b >= 0:
            _pyc_sy_work_push(b, 0)
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["JoinedStr"]:
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["FormattedValue"]:
        _pyc_sy_work_push(a, 0)
        return
    if kind == ND["Try"]:
        norelse = nd_obj[nid] & 65535
        nfinal = nd_obj[nid] >> 16
        base = a + b + c
        i = nfinal
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[base + norelse + i], 0)
        i = norelse
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[base + i], 0)
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + b + i], 0)
        i = b
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[a + i], 0)
        return
    if kind == ND["ExceptHandler"]:
        i = c
        while i > 0:
            i = i - 1
            _pyc_sy_work_push(kids[b + i], 0)
        if a >= 0:
            _pyc_sy_work_push(a, 0)
        obj = nd_obj[nid]
        # Bare except uses ""; a name is a str. Mixed-tag != TYPE-traps.
        if obj == "":
            return
        hid = _pyc_nd_new(ND["Name"], 1, 0, ND["Store"], 0, 0, obj)
        _pyc_sy_work_push(hid, 0)
        return
    if (
        kind == ND["Name"]
        or kind == ND["Constant"]
        or kind == ND["Global"]
        or kind == ND["FunctionDef"]
        or kind == ND["Pass"]
        or kind == ND["Break"]
        or kind == ND["Continue"]
    ):
        return
    _pyc_parse_error("unsupported node in symbol table")


def _pyc_symtab(root):
    global sc_n, sc_kind, sc_parent, sc_node, sc_nlocals, sc_argcount
    global sc_varnames, opnd, opnd_n, ops, stmts, stmt_n
    global sc_kwonly, sc_flags, sc_defaults, sc_kwdefaults
    cap = nd_n
    if cap < 8:
        cap = 8
    sc_kind = [0] * cap
    sc_parent = [0] * cap
    sc_node = [0] * cap
    sc_nlocals = [0] * cap
    sc_argcount = [0] * cap
    sc_varnames = [0] * cap
    sc_kwonly = [0] * cap
    sc_flags = [0] * cap
    sc_defaults = [0] * cap
    sc_kwdefaults = [0] * cap
    sc_n = 0
    gdecl = [0] * cap
    gdecl_n = [0] * cap
    uses = [0] * cap
    uses_n = [0] * cap
    sc_free = [0] * cap
    sc_free_n = [0] * cap
    opnd_n = 0
    stmts = [0] * 8
    stmt_n = 0
    sid0 = _pyc_sy_new_scope(0, 0 - 1, root)
    gdecl[sid0] = [0] * 8
    gdecl_n[sid0] = 0
    uses[sid0] = [0] * 8
    uses_n[sid0] = 0
    sc_free[sid0] = [0] * 8
    sc_free_n[sid0] = 0
    stmts[0] = sid0
    stmt_n = 1
    _pyc_sy_work_push(root, 0)
    load_k = ND["Load"]
    store_k = ND["Store"]
    fn_k = ND["FunctionDef"]
    lam_k = ND["Lambda"]
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
                if kind != lam_k:
                    continue
            nloc = sc_nlocals[cur]
            if nloc > 240:
                _pyc_parse_error("too many locals")
            stmt_n = stmt_n - 1
            continue
        if kind == fn_k or kind == lam_k:
            nargs = nd_b[nid] & 65535
            ndec = (nd_b[nid] >> 16) & 65535
            params = nd_b[nid] >> 32
            nbody = nd_c[nid]
            ks = nd_a[nid]
            if phase == 0:
                if kind == fn_k:
                    fname = nd_obj[nid][0]
                    if sc_kind[cur] == 1:
                        names, n = _pyc_sy_names_add(
                            sc_varnames[cur], sc_nlocals[cur], fname
                        )
                        sc_varnames[cur] = names
                        sc_nlocals[cur] = n
                _pyc_sy_work_push(nid, 2)
                j = ndec
                while j > 0:
                    j = j - 1
                    _pyc_sy_work_push(kids[ks + j], 0)
                continue
            sid = _pyc_sy_new_scope(1, cur, nid)
            gdecl[sid] = [0] * 8
            gdecl_n[sid] = 0
            uses[sid] = [0] * 8
            uses_n[sid] = 0
            capf = len(sc_free)
            while capf < sid + 1:
                extra = capf
                if extra < 8:
                    extra = 8
                sc_free = sc_free + ([0] * extra)
                sc_free_n = sc_free_n + ([0] * extra)
                capf = len(sc_free)
            sc_free[sid] = [0] * 8
            sc_free_n[sid] = 0
            # co_argcount is the positional count; nargs is nlocalsplus
            # for the parameters (positional + kw-only + *args + **kwargs).
            sc_argcount[sid] = params & 65535
            sc_kwonly[sid] = (params >> 16) & 4095
            sc_flags[sid] = (params >> 28) & 3
            sc_defaults[sid] = nd_obj[nid][1]
            sc_kwdefaults[sid] = nd_obj[nid][2]
            j = 0
            while j < nargs:
                arg_nid = kids[ks + ndec + j]
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
                _pyc_sy_work_push(kids[ks + ndec + nargs + j], 0)
            continue
        if kind == name_k:
            name = nd_obj[nid]
            ctx = nd_a[nid]
            if ctx == store_k or ctx == ND["Del"]:
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
    i = 0
    while i < sc_n:
        if sc_kind[i] != 1:
            i = i + 1
            continue
        nloc = sc_nlocals[i]
        un = uses_n[i]
        ui = 0
        while ui < un:
            name = uses[i][ui]
            if _pyc_sy_names_has(sc_varnames[i], nloc, name):
                ui = ui + 1
                continue
            if _pyc_sy_names_has(gdecl[i], gdecl_n[i], name):
                ui = ui + 1
                continue
            p = sc_parent[i]
            found_def = 0
            def_p = 0 - 1
            while p >= 0:
                if sc_kind[p] == 1:
                    if _pyc_sy_names_has(
                        sc_varnames[p], sc_nlocals[p], name
                    ):
                        if _pyc_sy_names_has(
                            gdecl[p], gdecl_n[p], name
                        ) == 0:
                            found_def = 1
                            def_p = p
                            break
                p = sc_parent[p]
            if found_def:
                xs, n = _pyc_sy_names_add(sc_free[i], sc_free_n[i], name)
                sc_free[i] = xs
                sc_free_n[i] = n
                q = sc_parent[i]
                while q != def_p:
                    if q < 0:
                        break
                    if sc_kind[q] == 1:
                        if _pyc_sy_names_has(
                            sc_varnames[q], sc_nlocals[q], name
                        ) == 0:
                            if _pyc_sy_names_has(
                                gdecl[q], gdecl_n[q], name
                            ) == 0:
                                xs, n = _pyc_sy_names_add(
                                    sc_free[q], sc_free_n[q], name
                                )
                                sc_free[q] = xs
                                sc_free_n[q] = n
                    q = sc_parent[q]
            ui = ui + 1
        i = i + 1
    i = 0
    while i < sc_n:
        if sc_kind[i] == 1:
            fn = sc_free_n[i]
            j = 0
            while j < fn:
                names, n = _pyc_sy_names_add(
                    sc_varnames[i], sc_nlocals[i], sc_free[i][j]
                )
                sc_varnames[i] = names
                sc_nlocals[i] = n
                j = j + 1
            if sc_nlocals[i] > 240:
                _pyc_parse_error("too many locals")
            sc_kind[i] = 1 + (fn << 8)
        i = i + 1
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
