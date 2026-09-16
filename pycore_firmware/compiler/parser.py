# Firmware T1–T3 parser (compiler_design.md §5.5 / steps F, J).
# Iterative shunting-yard over tk_* arrays into SoA nd_* / kids.
# Node kinds are CPython 3.14 ast type integers from generated ND.
#
# FunctionDef packing: nd_obj=name, nd_a=kids start, nd_b=nargs, nd_c=n_body.
# If packing: nd_a=test, nd_b=kids start, nd_c=n_body, nd_obj=n_orelse.
# While packing: nd_a=test, nd_b=kids start, nd_c=n_body.
# For packing: nd_a=target, nd_b=iter, nd_c=kids start, nd_obj=n_body.
# AugAssign: nd_a=target, nd_b=op kind, nd_c=value.
# Delete: nd_a=kids start, nd_b=n_targets.
# List/Tuple/Set: nd_a=kids start, nd_b=n, nd_c=ctx.
# Dict: nd_a=kids start, nd_b=n_pairs (key/value interleaved).
# Global packing: nd_obj=list of name strings, nd_a=count.
#
# Operator-stack tags (LOAD_CONST, not _PYC_G names):
#   1 BinOp  2 UnaryOp  3 (  4 call  5 [subscr]  6 Compare  7 BoolOp
#   8 list   9 tuple   10 dict/set
# Call / BoolOp / Compare / displays keep children on the operand stack and
# only write the kids arena when the node is reduced.


def _pyc_parse_error(msg):
    raise SyntaxError(msg)


def _pyc_nd_new(kind, line, col, a, b, c, obj):
    global nd_kind, nd_pos, nd_a, nd_b, nd_c, nd_obj, nd_n
    cap = len(nd_kind)
    while cap < nd_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        nd_kind = nd_kind + ([0] * extra)
        nd_pos = nd_pos + ([0] * extra)
        nd_a = nd_a + ([0] * extra)
        nd_b = nd_b + ([0] * extra)
        nd_c = nd_c + ([0] * extra)
        nd_obj = nd_obj + ([0] * extra)
        cap = len(nd_kind)
    nd_kind[nd_n] = kind
    nd_pos[nd_n] = line | (col << 32)
    nd_a[nd_n] = a
    nd_b[nd_n] = b
    nd_c[nd_n] = c
    nd_obj[nd_n] = obj
    nid = nd_n
    nd_n = nd_n + 1
    return nid


def _pyc_kids_append(nid):
    global kids, kids_n
    cap = len(kids)
    while cap < kids_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        kids = kids + ([0] * extra)
        cap = len(kids)
    kids[kids_n] = nid
    kids_n = kids_n + 1


def _pyc_opnd_push(nid):
    global opnd, opnd_n
    cap = len(opnd)
    while cap < opnd_n + 1:
        extra = cap
        if extra < 8:
            extra = 8
        opnd = opnd + ([0] * extra)
        cap = len(opnd)
    opnd[opnd_n] = nid
    opnd_n = opnd_n + 1


def _pyc_opnd_pop():
    global opnd_n
    if opnd_n < 1:
        _pyc_parse_error("expression stack underflow")
    opnd_n = opnd_n - 1
    return opnd[opnd_n]


def _pyc_ops_push(tag, a, b, extra):
    global ops, ops_obj, ops_n
    cap = len(ops)
    while cap < ops_n + 1:
        more = cap
        if more < 8:
            more = 8
        ops = ops + ([0] * more)
        ops_obj = ops_obj + ([0] * more)
        cap = len(ops)
    ops[ops_n] = tag | (a << 8) | (b << 32)
    ops_obj[ops_n] = extra
    ops_n = ops_n + 1


def _pyc_ops_pop():
    global ops_n
    if ops_n < 1:
        _pyc_parse_error("operator stack underflow")
    ops_n = ops_n - 1
    packed = ops[ops_n]
    extra = ops_obj[ops_n]
    tag = packed & 255
    a = (packed >> 8) & 16777215
    b = packed >> 32
    return tag, a, b, extra


def _pyc_tok_kind():
    if _parse_i >= tk_n:
        return TOK_ENDMARKER
    return tk_a[_parse_i] & 255


def _pyc_tok_text():
    if _parse_i >= tk_n:
        return ""
    return tk_s[_parse_i]


def _pyc_tok_line():
    if _parse_i >= tk_n:
        return 1
    return tk_a[_parse_i] >> 24


def _pyc_tok_col():
    if _parse_i >= tk_n:
        return 0
    return (tk_a[_parse_i] >> 8) & 65535


def _pyc_tok_advance():
    global _parse_i
    if _parse_i < tk_n:
        _parse_i = _parse_i + 1


def _pyc_pos_of(nid):
    p = nd_pos[nid]
    line = p & 4294967295
    col = p >> 32
    return line, col


def _pyc_digit_val(ch, base):
    digits = "0123456789abcdefABCDEF"
    d = digits.find(ch)
    if d < 0:
        return -1
    if d >= 16:
        d = d - 6
    if d >= base:
        return -1
    return d


def _pyc_parse_int_base(text, start, base):
    n = len(text)
    i = start
    if i >= n:
        _pyc_parse_error("invalid number")
    val = 0
    saw = 0
    while i < n:
        ch = text[i]
        if ch == "_":
            i = i + 1
            continue
        d = _pyc_digit_val(ch, base)
        if d < 0:
            _pyc_parse_error("invalid number")
        val = val * base + d
        saw = 1
        i = i + 1
    if saw == 0:
        _pyc_parse_error("invalid number")
    return val


def _pyc_parse_number(text):
    n = len(text)
    if n < 1:
        _pyc_parse_error("invalid number")
    has_dot = 0
    has_exp = 0
    i = 0
    while i < n:
        ch = text[i]
        if ch == ".":
            has_dot = 1
        elif ch == "e" or ch == "E":
            has_exp = 1
        elif ch == "j" or ch == "J":
            _pyc_parse_error("complex literals are not supported")
        i = i + 1
    if n >= 2 and text[0] == "0":
        ch = text[1]
        if ch == "x" or ch == "X":
            return [_pyc_parse_int_base(text, 2, 16), 0]
        if ch == "o" or ch == "O":
            return [_pyc_parse_int_base(text, 2, 8), 0]
        if ch == "b" or ch == "B":
            return [_pyc_parse_int_base(text, 2, 2), 0]
        if ch == "e" or ch == "E" or ch == ".":
            return [float(text), 1]
        if ch >= "0" and ch <= "9":
            _pyc_parse_error(
                "leading zeros in decimal integer literals are not permitted"
            )
    if has_dot or has_exp:
        return [float(text), 1]
    return [_pyc_parse_int_base(text, 0, 10), 0]


def _pyc_parse_string(text):
    n = len(text)
    i = 0
    while i < n:
        ch = text[i]
        if ch == "'" or ch == '"':
            break
        if ch == "b" or ch == "B":
            _pyc_parse_error("bytes literals are not supported")
        if ch == "f" or ch == "F" or ch == "t" or ch == "T":
            _pyc_parse_error("f-strings are not supported")
        i = i + 1
    if i >= n:
        _pyc_parse_error("invalid string literal")
    quote = text[i]
    qlen = 1
    if i + 2 < n and text[i + 1] == quote and text[i + 2] == quote:
        qlen = 3
    start = i + qlen
    end = n - qlen
    if end < start:
        _pyc_parse_error("invalid string literal")
    return text[start:end]


def _pyc_set_store(nid):
    kind = nd_kind[nid]
    ctx = ND["Store"]
    if _lex_i == 0 - 2:
        ctx = ND["Del"]
    if kind == ND["Name"]:
        nd_a[nid] = ctx
        return
    if kind == ND["Attribute"] or kind == ND["Subscript"]:
        nd_c[nid] = ctx
        return
    if kind == ND["Tuple"] or kind == ND["List"]:
        nd_c[nid] = ctx
        n = nd_b[nid]
        ks = nd_a[nid]
        i = 0
        while i < n:
            _pyc_set_store(kids[ks + i])
            i = i + 1
        return
    _pyc_parse_error("cannot assign to this expression")


def _pyc_flush_n(n):
    if n < 0:
        _pyc_parse_error("negative arity")
    arr = [0] * n
    i = 0
    while i < n:
        arr[n - 1 - i] = _pyc_opnd_pop()
        i = i + 1
    ks = kids_n
    i = 0
    while i < n:
        _pyc_kids_append(arr[i])
        i = i + 1
    return ks


def _pyc_reduce_one():
    tag, a, b, extra = _pyc_ops_pop()
    if tag == 1:
        right = _pyc_opnd_pop()
        left = _pyc_opnd_pop()
        line, col = _pyc_pos_of(left)
        nid = _pyc_nd_new(ND["BinOp"], line, col, left, a, right, 0)
        _pyc_opnd_push(nid)
        return
    if tag == 2:
        operand = _pyc_opnd_pop()
        line = extra & 4294967295
        col = extra >> 32
        nid = _pyc_nd_new(ND["UnaryOp"], line, col, a, operand, 0, 0)
        _pyc_opnd_push(nid)
        return
    if tag == 6:
        n_comp = b + 1
        ks = _pyc_flush_n(n_comp)
        left = _pyc_opnd_pop()
        line, col = _pyc_pos_of(left)
        nid = _pyc_nd_new(ND["Compare"], line, col, left, ks, n_comp, extra)
        _pyc_opnd_push(nid)
        return
    if tag == 7:
        n_val = b + 1
        ks = _pyc_flush_n(n_val)
        line, col = _pyc_pos_of(kids[ks])
        nid = _pyc_nd_new(ND["BoolOp"], line, col, a, ks, n_val, 0)
        _pyc_opnd_push(nid)
        return
    _pyc_parse_error("internal parser reduce")


def _pyc_top_prec():
    if ops_n < 1:
        return -1
    packed = ops[ops_n - 1]
    tag = packed & 255
    a = (packed >> 8) & 16777215
    b = packed >> 32
    if tag == 1:
        return b
    if tag == 2:
        return b
    if tag == 6:
        return PREC["cmp"]
    if tag == 7:
        if a == ND["And"]:
            return PREC["and"]
        return PREC["or"]
    return -1


def _pyc_top_tag():
    if ops_n < 1:
        return 0
    return ops[ops_n - 1] & 255


def _pyc_reduce_while(prec, left_assoc):
    while 1:
        top = _pyc_top_prec()
        if top < 0:
            return
        if left_assoc:
            if top < prec:
                return
        else:
            if top <= prec:
                return
        _pyc_reduce_one()


def _pyc_cmp_kind():
    kind = _pyc_tok_kind()
    text = _pyc_tok_text()
    if kind == TOK_OP:
        if text in CMPOPS:
            return CMPOPS[text]
        return 0
    if kind != TOK_NAME:
        return 0
    if text == "is":
        return ND["Is"]
    if text == "in":
        return ND["In"]
    if text == "not":
        return ND["NotIn"]
    return 0


def _pyc_consume_cmp():
    kind = _pyc_tok_kind()
    text = _pyc_tok_text()
    if kind == TOK_OP:
        ck = CMPOPS[text]
        _pyc_tok_advance()
        return ck
    if text == "is":
        _pyc_tok_advance()
        if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "not":
            _pyc_tok_advance()
            return ND["IsNot"]
        return ND["Is"]
    if text == "not":
        _pyc_tok_advance()
        if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "in":
            _pyc_tok_advance()
            return ND["NotIn"]
        _pyc_parse_error("expected 'in' after 'not'")
    if text == "in":
        _pyc_tok_advance()
        return ND["In"]
    _pyc_parse_error("invalid comparison")


def _pyc_close_call(want):
    tag, func, nargs, extra = _pyc_ops_pop()
    if tag != 4:
        _pyc_parse_error("unmatched ')'")
    if want:
        if nargs == 0:
            n = 0
        else:
            n = nargs
    else:
        n = nargs + 1
    ks = _pyc_flush_n(n)
    line, col = _pyc_pos_of(func)
    nid = _pyc_nd_new(ND["Call"], line, col, func, ks, n, 0)
    _pyc_opnd_push(nid)
    _pyc_tok_advance()


def _pyc_parse_expr():
    global opnd_n, ops_n
    want = 1
    start_opnd = opnd_n
    start_ops = ops_n
    while 1:
        kind = _pyc_tok_kind()
        text = _pyc_tok_text()
        if kind == TOK_ENDMARKER or kind == TOK_NEWLINE or kind == TOK_DEDENT:
            break
        if kind == TOK_INDENT:
            _pyc_parse_error("unexpected indent")
        if want:
            if kind == TOK_NUMBER:
                line = _pyc_tok_line()
                col = _pyc_tok_col()
                pair = _pyc_parse_number(text)
                nid = _pyc_nd_new(ND["Constant"], line, col, pair[1], 0, 0, pair[0])
                _pyc_opnd_push(nid)
                _pyc_tok_advance()
                want = 0
                continue
            if kind == TOK_STRING:
                line = _pyc_tok_line()
                col = _pyc_tok_col()
                val = _pyc_parse_string(text)
                nid = _pyc_nd_new(ND["Constant"], line, col, 2, 0, 0, val)
                _pyc_opnd_push(nid)
                _pyc_tok_advance()
                want = 0
                continue
            if kind == TOK_NAME:
                if text == "True":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    nid = _pyc_nd_new(ND["Constant"], line, col, 3, 0, 0, True)
                    _pyc_opnd_push(nid)
                    _pyc_tok_advance()
                    want = 0
                    continue
                if text == "False":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    nid = _pyc_nd_new(ND["Constant"], line, col, 4, 0, 0, False)
                    _pyc_opnd_push(nid)
                    _pyc_tok_advance()
                    want = 0
                    continue
                if text == "None":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    nid = _pyc_nd_new(ND["Constant"], line, col, 5, 0, 0, None)
                    _pyc_opnd_push(nid)
                    _pyc_tok_advance()
                    want = 0
                    continue
                if text == "not":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    _pyc_ops_push(2, ND["Not"], PREC["not"], line | (col << 32))
                    _pyc_tok_advance()
                    want = 1
                    continue
                if text in KEYWORDS:
                    _pyc_parse_error("unsupported expression keyword '" + text + "'")
                line = _pyc_tok_line()
                col = _pyc_tok_col()
                nid = _pyc_nd_new(
                    ND["Name"], line, col, ND["Load"], 0, 0, text
                )
                _pyc_opnd_push(nid)
                _pyc_tok_advance()
                want = 0
                continue
            if kind == TOK_OP:
                if text == "(":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    _pyc_ops_push(3, 0, 0, line | (col << 32))
                    _pyc_tok_advance()
                    want = 1
                    continue
                if text in UNOPS:
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    _pyc_ops_push(2, UNOPS[text], PREC["u"], line | (col << 32))
                    _pyc_tok_advance()
                    want = 1
                    continue
                if text == "[":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    _pyc_ops_push(8, 0, 0, line | (col << 32))
                    _pyc_tok_advance()
                    want = 1
                    continue
                if text == "{":
                    line = _pyc_tok_line()
                    col = _pyc_tok_col()
                    _pyc_ops_push(10, 0, 0, line | (col << 32))
                    _pyc_tok_advance()
                    want = 1
                    continue
                if (
                    text == ")"
                    or text == "]"
                    or text == "}"
                    or text == ","
                    or text == ":"
                    or text == "="
                ):
                    pass
                else:
                    _pyc_parse_error("expected expression")
            else:
                _pyc_parse_error("expected expression")
        if kind == TOK_OP and text == "(":
            func = _pyc_opnd_pop()
            _pyc_ops_push(4, func, 0, 0)
            _pyc_tok_advance()
            kind2 = _pyc_tok_kind()
            text2 = _pyc_tok_text()
            if kind2 == TOK_OP and text2 == ")":
                _pyc_close_call(1)
                want = 0
                continue
            want = 1
            continue
        if kind == TOK_OP and text == "[":
            _pyc_ops_push(5, 0, 0, 0)
            _pyc_tok_advance()
            want = 1
            continue
        if kind == TOK_OP and text == ".":
            value = _pyc_opnd_pop()
            line, col = _pyc_pos_of(value)
            _pyc_tok_advance()
            if _pyc_tok_kind() != TOK_NAME:
                _pyc_parse_error("expected attribute name")
            attr = _pyc_tok_text()
            nid = _pyc_nd_new(
                ND["Attribute"], line, col, value, 0, ND["Load"], attr
            )
            _pyc_opnd_push(nid)
            _pyc_tok_advance()
            want = 0
            continue
        if kind == TOK_OP and text == ")":
            while ops_n > start_ops:
                tag = _pyc_top_tag()
                if tag == 3 or tag == 4 or tag == 9:
                    break
                if tag == 5 or tag == 8:
                    _pyc_parse_error("unmatched ']'")
                if tag == 10:
                    _pyc_parse_error("unmatched '}'")
                _pyc_reduce_one()
            if ops_n <= start_ops:
                break
            tag = _pyc_top_tag()
            if tag == 3:
                if want:
                    tag, a, b, extra = _pyc_ops_pop()
                    line = extra & 4294967295
                    col = extra >> 32
                    nid = _pyc_nd_new(
                        ND["Tuple"], line, col, kids_n, 0, ND["Load"], 0
                    )
                    _pyc_opnd_push(nid)
                else:
                    _pyc_ops_pop()
                _pyc_tok_advance()
                want = 0
                continue
            if tag == 9:
                packed = ops[ops_n - 1]
                nargs = (packed >> 8) & 16777215
                extra = ops_obj[ops_n - 1]
                _pyc_ops_pop()
                if want:
                    n = nargs
                else:
                    n = nargs + 1
                ks = _pyc_flush_n(n)
                line = extra & 4294967295
                col = extra >> 32
                nid = _pyc_nd_new(
                    ND["Tuple"], line, col, ks, n, ND["Load"], 0
                )
                _pyc_opnd_push(nid)
                _pyc_tok_advance()
                want = 0
                continue
            if tag == 4:
                _pyc_close_call(want)
                want = 0
                continue
            _pyc_parse_error("unmatched ')'")
        if kind == TOK_OP and text == "]":
            while ops_n > start_ops:
                tag = _pyc_top_tag()
                if tag == 5 or tag == 8:
                    break
                if tag == 3 or tag == 4 or tag == 9:
                    _pyc_parse_error("unmatched bracket")
                if tag == 10:
                    _pyc_parse_error("unmatched '}'")
                _pyc_reduce_one()
            if ops_n <= start_ops:
                _pyc_parse_error("unmatched ']'")
            tag = _pyc_top_tag()
            if tag == 8:
                packed = ops[ops_n - 1]
                nargs = (packed >> 8) & 16777215
                extra = ops_obj[ops_n - 1]
                _pyc_ops_pop()
                if want:
                    n = nargs
                else:
                    n = nargs + 1
                ks = _pyc_flush_n(n)
                line = extra & 4294967295
                col = extra >> 32
                nid = _pyc_nd_new(
                    ND["List"], line, col, ks, n, ND["Load"], 0
                )
                _pyc_opnd_push(nid)
                _pyc_tok_advance()
                want = 0
                continue
            if tag != 5:
                _pyc_parse_error("unmatched ']'")
            _pyc_ops_pop()
            if want:
                _pyc_parse_error("expected subscript")
            slc = _pyc_opnd_pop()
            value = _pyc_opnd_pop()
            line, col = _pyc_pos_of(value)
            nid = _pyc_nd_new(
                ND["Subscript"], line, col, value, slc, ND["Load"], 0
            )
            _pyc_opnd_push(nid)
            _pyc_tok_advance()
            want = 0
            continue
        if kind == TOK_OP and text == "}":
            while ops_n > start_ops:
                tag = _pyc_top_tag()
                if tag == 10:
                    break
                if tag == 3 or tag == 4 or tag == 9:
                    _pyc_parse_error("unmatched '}'")
                if tag == 5 or tag == 8:
                    _pyc_parse_error("unmatched ']'")
                _pyc_reduce_one()
            if ops_n <= start_ops or _pyc_top_tag() != 10:
                _pyc_parse_error("unmatched '}'")
            packed = ops[ops_n - 1]
            nargs = (packed >> 8) & 16777215
            kind_ds = packed >> 32
            extra = ops_obj[ops_n - 1]
            _pyc_ops_pop()
            if want:
                n = nargs
            else:
                n = nargs + 1
            line = extra & 4294967295
            col = extra >> 32
            if kind_ds == 0:
                if n == 0:
                    nid = _pyc_nd_new(
                        ND["Dict"], line, col, kids_n, 0, 0, 0
                    )
                    _pyc_opnd_push(nid)
                else:
                    ks = _pyc_flush_n(n)
                    nid = _pyc_nd_new(
                        ND["Set"], line, col, ks, n, ND["Load"], 0
                    )
                    _pyc_opnd_push(nid)
            elif kind_ds == 1:
                if want:
                    _pyc_parse_error("expected value in dict display")
                n_ops = (nargs + 1) * 2
                ks = _pyc_flush_n(n_ops)
                n_pairs = nargs + 1
                nid = _pyc_nd_new(
                    ND["Dict"], line, col, ks, n_pairs, 0, 0
                )
                _pyc_opnd_push(nid)
            elif kind_ds == 3:
                if want == 0:
                    _pyc_parse_error("expected ':' in dict display")
                n_ops = nargs * 2
                ks = _pyc_flush_n(n_ops)
                nid = _pyc_nd_new(
                    ND["Dict"], line, col, ks, nargs, 0, 0
                )
                _pyc_opnd_push(nid)
            else:
                ks = _pyc_flush_n(n)
                nid = _pyc_nd_new(
                    ND["Set"], line, col, ks, n, ND["Load"], 0
                )
                _pyc_opnd_push(nid)
            _pyc_tok_advance()
            want = 0
            continue
        if kind == TOK_OP and text == ",":
            while ops_n > start_ops:
                tag = _pyc_top_tag()
                if (
                    tag == 3
                    or tag == 4
                    or tag == 5
                    or tag == 8
                    or tag == 9
                    or tag == 10
                ):
                    break
                _pyc_reduce_one()
            if want:
                _pyc_parse_error("expected expression")
            tag = _pyc_top_tag()
            if tag == 4:
                packed = ops[ops_n - 1]
                func = (packed >> 8) & 16777215
                nargs = (packed >> 32) + 1
                ops[ops_n - 1] = 4 | (func << 8) | (nargs << 32)
                _pyc_tok_advance()
                kind2 = _pyc_tok_kind()
                text2 = _pyc_tok_text()
                if kind2 == TOK_OP and text2 == ")":
                    _pyc_close_call(1)
                    want = 0
                    continue
                want = 1
                continue
            if tag == 3:
                extra = ops_obj[ops_n - 1]
                ops[ops_n - 1] = 9 | (1 << 8)
                ops_obj[ops_n - 1] = extra
                _pyc_tok_advance()
                want = 1
                continue
            if tag == 8 or tag == 9:
                packed = ops[ops_n - 1]
                extra = ops_obj[ops_n - 1]
                nargs = ((packed >> 8) & 16777215) + 1
                ops[ops_n - 1] = tag | (nargs << 8)
                ops_obj[ops_n - 1] = extra
                _pyc_tok_advance()
                want = 1
                continue
            if tag == 10:
                packed = ops[ops_n - 1]
                extra = ops_obj[ops_n - 1]
                nargs = ((packed >> 8) & 16777215) + 1
                kind_ds = packed >> 32
                if kind_ds == 1:
                    kind_ds = 3
                elif kind_ds == 0:
                    kind_ds = 2
                ops[ops_n - 1] = 10 | (nargs << 8) | (kind_ds << 32)
                ops_obj[ops_n - 1] = extra
                _pyc_tok_advance()
                want = 1
                continue
            extra = _pyc_tok_line() | (_pyc_tok_col() << 32)
            _pyc_ops_push(9, 1, 0, extra)
            _pyc_tok_advance()
            want = 1
            continue
        if kind == TOK_OP and text == ":":
            while ops_n > start_ops:
                tag = _pyc_top_tag()
                if tag == 10:
                    break
                if tag == 5:
                    _pyc_parse_error("slices are not supported")
                if (
                    tag == 3
                    or tag == 4
                    or tag == 8
                    or tag == 9
                ):
                    break
                _pyc_reduce_one()
            tag = _pyc_top_tag()
            if tag == 10:
                if want:
                    _pyc_parse_error("expected key")
                packed = ops[ops_n - 1]
                extra = ops_obj[ops_n - 1]
                nargs = (packed >> 8) & 16777215
                kind_ds = packed >> 32
                if kind_ds == 2:
                    _pyc_parse_error("invalid dict display")
                ops[ops_n - 1] = 10 | (nargs << 8) | (1 << 32)
                ops_obj[ops_n - 1] = extra
                _pyc_tok_advance()
                want = 1
                continue
            break
        if kind == TOK_OP and text == "=":
            break
        if kind == TOK_NAME and text == "and":
            _pyc_reduce_while(PREC["and"], 0)
            if _pyc_top_tag() == 7:
                packed = ops[ops_n - 1]
                a = (packed >> 8) & 16777215
                b = packed >> 32
                if a == ND["And"]:
                    ops[ops_n - 1] = 7 | (a << 8) | ((b + 1) << 32)
                    _pyc_tok_advance()
                    want = 1
                    continue
            _pyc_ops_push(7, ND["And"], 1, 0)
            _pyc_tok_advance()
            want = 1
            continue
        if kind == TOK_NAME and text == "or":
            _pyc_reduce_while(PREC["or"], 0)
            if _pyc_top_tag() == 7:
                packed = ops[ops_n - 1]
                a = (packed >> 8) & 16777215
                b = packed >> 32
                if a == ND["Or"]:
                    ops[ops_n - 1] = 7 | (a << 8) | ((b + 1) << 32)
                    _pyc_tok_advance()
                    want = 1
                    continue
            _pyc_ops_push(7, ND["Or"], 1, 0)
            _pyc_tok_advance()
            want = 1
            continue
        ck = _pyc_cmp_kind()
        if ck != 0:
            if kind == TOK_NAME and text == "not":
                nxt_i = _parse_i + 1
                if nxt_i >= tk_n:
                    _pyc_parse_error("expected 'in'")
                nxt_kind = tk_a[nxt_i] & 255
                nxt_text = tk_s[nxt_i]
                if not (nxt_kind == TOK_NAME and nxt_text == "in"):
                    _pyc_parse_error("expected 'in' after 'not'")
            _pyc_reduce_while(PREC["cmp"], 0)
            ck = _pyc_consume_cmp()
            if _pyc_top_tag() == 6:
                packed = ops[ops_n - 1]
                a = (packed >> 8) & 16777215
                b = packed >> 32
                extra = ops_obj[ops_n - 1] + [ck]
                ops[ops_n - 1] = 6 | (a << 8) | ((b + 1) << 32)
                ops_obj[ops_n - 1] = extra
                want = 1
                continue
            _pyc_ops_push(6, 0, 0, [ck])
            want = 1
            continue
        if kind == TOK_OP and text in BINOPS:
            prec = PREC[text]
            left_assoc = 1
            if text in RIGHTASSOC:
                left_assoc = 0
            _pyc_reduce_while(prec, left_assoc)
            _pyc_ops_push(1, BINOPS[text], prec, 0)
            _pyc_tok_advance()
            want = 1
            continue
        break
    if want:
        tag = _pyc_top_tag()
        if tag != 9:
            if tag != 8:
                _pyc_parse_error("unexpected end of expression")
    while ops_n > start_ops:
        tag = _pyc_top_tag()
        if tag == 9:
            packed = ops[ops_n - 1]
            nargs = (packed >> 8) & 16777215
            extra = ops_obj[ops_n - 1]
            _pyc_ops_pop()
            if want:
                n = nargs
            else:
                n = nargs + 1
            ks = _pyc_flush_n(n)
            line = extra & 4294967295
            col = extra >> 32
            nid = _pyc_nd_new(
                ND["Tuple"], line, col, ks, n, ND["Load"], 0
            )
            _pyc_opnd_push(nid)
            want = 0
            continue
        if tag == 3 or tag == 4 or tag == 5 or tag == 8 or tag == 10:
            _pyc_parse_error("unmatched bracket")
        _pyc_reduce_one()
    if opnd_n != start_opnd + 1:
        _pyc_parse_error("invalid expression")
    return _pyc_opnd_pop()


def _pyc_skip_newlines():
    while _pyc_tok_kind() == TOK_NEWLINE:
        _pyc_tok_advance()


def _pyc_parse_return():
    line = _pyc_tok_line()
    col = _pyc_tok_col()
    _pyc_tok_advance()
    kind = _pyc_tok_kind()
    if (
        kind == TOK_NEWLINE
        or kind == TOK_ENDMARKER
        or kind == TOK_DEDENT
    ):
        return _pyc_nd_new(ND["Return"], line, col, -1, 0, 0, 0)
    value = _pyc_parse_expr()
    return _pyc_nd_new(ND["Return"], line, col, value, 0, 0, 0)


def _pyc_parse_global():
    line = _pyc_tok_line()
    col = _pyc_tok_col()
    _pyc_tok_advance()
    names = [0] * 8
    nn = 0
    if _pyc_tok_kind() != TOK_NAME:
        _pyc_parse_error("expected name after global")
    while 1:
        if _pyc_tok_kind() != TOK_NAME:
            _pyc_parse_error("expected name")
        n = _pyc_tok_text()
        if n in KEYWORDS:
            _pyc_parse_error("invalid global name")
        cap = len(names)
        while cap < nn + 1:
            extra = cap
            if extra < 8:
                extra = 8
            names = names + ([0] * extra)
            cap = len(names)
        names[nn] = n
        nn = nn + 1
        _pyc_tok_advance()
        if _pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ",":
            _pyc_tok_advance()
            continue
        break
    out = [0] * nn
    i = 0
    while i < nn:
        out[i] = names[i]
        i = i + 1
    return _pyc_nd_new(ND["Global"], line, col, nn, 0, 0, out)


def _pyc_parse_suite():
    body = [0] * 8
    bn = 0
    if _pyc_tok_kind() == TOK_NEWLINE:
        _pyc_tok_advance()
        if _pyc_tok_kind() != TOK_INDENT:
            _pyc_parse_error("expected an indented block")
        _pyc_tok_advance()
        while 1:
            _pyc_skip_newlines()
            kind = _pyc_tok_kind()
            if kind == TOK_DEDENT:
                _pyc_tok_advance()
                break
            if kind == TOK_ENDMARKER:
                _pyc_parse_error("expected an indented block")
            stmt = _pyc_parse_stmt()
            cap = len(body)
            while cap < bn + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                body = body + ([0] * extra)
                cap = len(body)
            body[bn] = stmt
            bn = bn + 1
            kind = _pyc_tok_kind()
            if nd_kind[stmt] == ND["FunctionDef"]:
                continue
            if nd_kind[stmt] == ND["If"]:
                continue
            if nd_kind[stmt] == ND["While"]:
                continue
            if nd_kind[stmt] == ND["For"]:
                continue
            if kind == TOK_NEWLINE:
                _pyc_tok_advance()
                continue
            if kind == TOK_DEDENT:
                continue
            if kind == TOK_ENDMARKER:
                _pyc_parse_error("expected an indented block")
            _pyc_parse_error("unexpected input after statement")
        if bn < 1:
            _pyc_parse_error("expected an indented block")
        out = [0] * bn
        i = 0
        while i < bn:
            out[i] = body[i]
            i = i + 1
        return out
    stmt = _pyc_parse_stmt()
    out = [0] * 1
    out[0] = stmt
    return out


def _pyc_parse_function_def():
    line = _pyc_tok_line()
    col = _pyc_tok_col()
    _pyc_tok_advance()
    if _pyc_tok_kind() != TOK_NAME:
        _pyc_parse_error("expected function name")
    name = _pyc_tok_text()
    if name in KEYWORDS:
        _pyc_parse_error("invalid function name")
    _pyc_tok_advance()
    if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == "("):
        _pyc_parse_error("expected '('")
    _pyc_tok_advance()
    args = [0] * 8
    nargs = 0
    if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ")"):
        while 1:
            if _pyc_tok_kind() != TOK_NAME:
                _pyc_parse_error("unsupported function argument")
            aname = _pyc_tok_text()
            if aname in KEYWORDS:
                _pyc_parse_error("invalid argument name")
            aline = _pyc_tok_line()
            acol = _pyc_tok_col()
            _pyc_tok_advance()
            if _pyc_tok_kind() == TOK_OP and _pyc_tok_text() == "=":
                _pyc_parse_error("default arguments are not supported")
            nid = _pyc_nd_new(
                ND["Name"], aline, acol, ND["Store"], 0, 0, aname
            )
            cap = len(args)
            while cap < nargs + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                args = args + ([0] * extra)
                cap = len(args)
            args[nargs] = nid
            nargs = nargs + 1
            if _pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ",":
                _pyc_tok_advance()
                if _pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ")":
                    break
                continue
            break
    if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ")"):
        _pyc_parse_error("expected ')'")
    _pyc_tok_advance()
    if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ":"):
        _pyc_parse_error("expected ':'")
    _pyc_tok_advance()
    body = _pyc_parse_suite()
    nbody = len(body)
    ks = kids_n
    i = 0
    while i < nargs:
        _pyc_kids_append(args[i])
        i = i + 1
    i = 0
    while i < nbody:
        _pyc_kids_append(body[i])
        i = i + 1
    return _pyc_nd_new(
        ND["FunctionDef"], line, col, ks, nargs, nbody, name
    )


def _pyc_parse_stmt():
    global _lex_i
    kind = _pyc_tok_kind()
    text = _pyc_tok_text()
    if kind == TOK_NAME and text == "return":
        return _pyc_parse_return()
    if kind == TOK_NAME and text == "def":
        return _pyc_parse_function_def()
    if kind == TOK_NAME and text == "global":
        return _pyc_parse_global()
    if kind == TOK_NAME and text == "pass":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        return _pyc_nd_new(ND["Pass"], line, col, 0, 0, 0, 0)
    if kind == TOK_NAME and text == "break":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        return _pyc_nd_new(ND["Break"], line, col, 0, 0, 0, 0)
    if kind == TOK_NAME and text == "continue":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        return _pyc_nd_new(ND["Continue"], line, col, 0, 0, 0, 0)
    if kind == TOK_NAME and text == "del":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        target = _pyc_parse_expr()
        saved = _lex_i
        _lex_i = 0 - 2
        _pyc_set_store(target)
        _lex_i = saved
        if nd_kind[target] == ND["Tuple"]:
            return _pyc_nd_new(
                ND["Delete"], line, col, nd_a[target], nd_b[target], 0, 0
            )
        ks = kids_n
        _pyc_kids_append(target)
        return _pyc_nd_new(ND["Delete"], line, col, ks, 1, 0, 0)
    if kind == TOK_NAME and text == "if":
        tests = [0] * 8
        bodies = [0] * 8
        lines = [0] * 8
        cols = [0] * 8
        ncl = 0
        while 1:
            line = _pyc_tok_line()
            col = _pyc_tok_col()
            _pyc_tok_advance()
            test = _pyc_parse_expr()
            if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ":"):
                _pyc_parse_error("expected ':'")
            _pyc_tok_advance()
            body = _pyc_parse_suite()
            cap = len(tests)
            while cap < ncl + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tests = tests + ([0] * extra)
                bodies = bodies + ([0] * extra)
                lines = lines + ([0] * extra)
                cols = cols + ([0] * extra)
                cap = len(tests)
            tests[ncl] = test
            bodies[ncl] = body
            lines[ncl] = line
            cols[ncl] = col
            ncl = ncl + 1
            _pyc_skip_newlines()
            if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "elif":
                continue
            break
        orelse = [0] * 0
        if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "else":
            _pyc_tok_advance()
            if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ":"):
                _pyc_parse_error("expected ':'")
            _pyc_tok_advance()
            orelse = _pyc_parse_suite()
        i = ncl
        while i > 0:
            i = i - 1
            body = bodies[i]
            nbody = len(body)
            norelse = len(orelse)
            ks = kids_n
            j = 0
            while j < nbody:
                _pyc_kids_append(body[j])
                j = j + 1
            j = 0
            while j < norelse:
                _pyc_kids_append(orelse[j])
                j = j + 1
            nid = _pyc_nd_new(
                ND["If"],
                lines[i],
                cols[i],
                tests[i],
                ks,
                nbody,
                norelse,
            )
            if i == 0:
                return nid
            orelse = [0] * 1
            orelse[0] = nid
        _pyc_parse_error("internal if")
    if kind == TOK_NAME and text == "while":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        test = _pyc_parse_expr()
        if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ":"):
            _pyc_parse_error("expected ':'")
        _pyc_tok_advance()
        body = _pyc_parse_suite()
        _pyc_skip_newlines()
        if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "else":
            _pyc_parse_error("while-else is not supported")
        nbody = len(body)
        ks = kids_n
        i = 0
        while i < nbody:
            _pyc_kids_append(body[i])
            i = i + 1
        return _pyc_nd_new(ND["While"], line, col, test, ks, nbody, 0)
    if kind == TOK_NAME and text == "for":
        line = _pyc_tok_line()
        col = _pyc_tok_col()
        _pyc_tok_advance()
        if _pyc_tok_kind() != TOK_NAME:
            _pyc_parse_error("unsupported for-target")
        tname = _pyc_tok_text()
        if tname in KEYWORDS:
            _pyc_parse_error("invalid for-target")
        tline = _pyc_tok_line()
        tcol = _pyc_tok_col()
        _pyc_tok_advance()
        tnodes = [0] * 8
        nt = 0
        tnodes[0] = _pyc_nd_new(
            ND["Name"], tline, tcol, ND["Store"], 0, 0, tname
        )
        nt = 1
        while _pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ",":
            _pyc_tok_advance()
            if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "in":
                break
            if _pyc_tok_kind() != TOK_NAME:
                _pyc_parse_error("unsupported for-target")
            tname = _pyc_tok_text()
            if tname in KEYWORDS:
                _pyc_parse_error("invalid for-target")
            tline = _pyc_tok_line()
            tcol = _pyc_tok_col()
            _pyc_tok_advance()
            cap = len(tnodes)
            while cap < nt + 1:
                extra = cap
                if extra < 8:
                    extra = 8
                tnodes = tnodes + ([0] * extra)
                cap = len(tnodes)
            tnodes[nt] = _pyc_nd_new(
                ND["Name"], tline, tcol, ND["Store"], 0, 0, tname
            )
            nt = nt + 1
        if nt == 1:
            target = tnodes[0]
        else:
            ks = kids_n
            i = 0
            while i < nt:
                _pyc_kids_append(tnodes[i])
                i = i + 1
            target = _pyc_nd_new(
                ND["Tuple"], line, col, ks, nt, ND["Store"], 0
            )
        if not (_pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "in"):
            _pyc_parse_error("expected 'in'")
        _pyc_tok_advance()
        it = _pyc_parse_expr()
        if not (_pyc_tok_kind() == TOK_OP and _pyc_tok_text() == ":"):
            _pyc_parse_error("expected ':'")
        _pyc_tok_advance()
        body = _pyc_parse_suite()
        _pyc_skip_newlines()
        if _pyc_tok_kind() == TOK_NAME and _pyc_tok_text() == "else":
            _pyc_parse_error("for-else is not supported")
        nbody = len(body)
        ks = kids_n
        i = 0
        while i < nbody:
            _pyc_kids_append(body[i])
            i = i + 1
        return _pyc_nd_new(ND["For"], line, col, target, it, ks, nbody)
    if kind == TOK_NAME and text in KEYWORDS:
        if (
            text != "True"
            and text != "False"
            and text != "None"
            and text != "not"
        ):
            _pyc_parse_error("unsupported statement '" + text + "'")
    value = _pyc_parse_expr()
    kind = _pyc_tok_kind()
    text = _pyc_tok_text()
    if kind == TOK_OP and text == "=":
        _pyc_tok_advance()
        _pyc_set_store(value)
        rhs = _pyc_parse_expr()
        line, col = _pyc_pos_of(value)
        return _pyc_nd_new(ND["Assign"], line, col, value, 0, rhs, 0)
    if kind == TOK_OP:
        n = len(text)
        if n >= 2:
            last = text[n - 1]
            op = text[0 : n - 1]
            if last == "=":
                if op in BINOPS:
                    _pyc_tok_advance()
                    _pyc_set_store(value)
                    rhs = _pyc_parse_expr()
                    line, col = _pyc_pos_of(value)
                    return _pyc_nd_new(
                        ND["AugAssign"], line, col, value, BINOPS[op], rhs, 0
                    )
    line, col = _pyc_pos_of(value)
    return _pyc_nd_new(ND["Expr"], line, col, value, 0, 0, 0)


def _pyc_parse(mode):
    global _parse_i, nd_kind, nd_pos, nd_a, nd_b, nd_c, nd_obj, nd_n
    global kids, kids_n, opnd, opnd_n, ops, ops_obj, ops_n, stmts, stmt_n
    _parse_i = 0
    cap = tk_n
    if cap < 8:
        cap = 8
    nd_kind = [0] * cap
    nd_pos = [0] * cap
    nd_a = [0] * cap
    nd_b = [0] * cap
    nd_c = [0] * cap
    nd_obj = [0] * cap
    nd_n = 0
    kids = [0] * (cap * 2)
    kids_n = 0
    opnd = [0] * cap
    opnd_n = 0
    ops = [0] * cap
    ops_obj = [0] * cap
    ops_n = 0
    if mode == "eval":
        body = _pyc_parse_expr()
        _pyc_skip_newlines()
        if _pyc_tok_kind() != TOK_ENDMARKER:
            _pyc_parse_error("unexpected input after expression")
        line, col = _pyc_pos_of(body)
        return _pyc_nd_new(ND["Expression"], line, col, body, 0, 0, 0)
    if mode == "exec":
        stmts = [0] * cap
        stmt_n = 0
        while 1:
            _pyc_skip_newlines()
            kind = _pyc_tok_kind()
            if kind == TOK_ENDMARKER:
                break
            if kind == TOK_DEDENT:
                _pyc_parse_error("unindent does not match any outer indentation")
            if kind == TOK_INDENT:
                _pyc_parse_error("unexpected indent")
            stmt = _pyc_parse_stmt()
            sc = len(stmts)
            while sc < stmt_n + 1:
                more = sc
                if more < 8:
                    more = 8
                stmts = stmts + ([0] * more)
                sc = len(stmts)
            stmts[stmt_n] = stmt
            stmt_n = stmt_n + 1
            kind = _pyc_tok_kind()
            if nd_kind[stmt] == ND["FunctionDef"]:
                continue
            if nd_kind[stmt] == ND["If"]:
                continue
            if nd_kind[stmt] == ND["While"]:
                continue
            if nd_kind[stmt] == ND["For"]:
                continue
            if kind == TOK_NEWLINE:
                _pyc_tok_advance()
                continue
            if kind == TOK_ENDMARKER:
                continue
            _pyc_parse_error("unexpected input after statement")
        ks = kids_n
        i = 0
        while i < stmt_n:
            _pyc_kids_append(stmts[i])
            i = i + 1
        return _pyc_nd_new(ND["Module"], 1, 0, ks, stmt_n, 0, 0)
    _pyc_parse_error("unsupported compile mode")


def _pyc_ast_checksum():
    cs = nd_n
    i = 0
    while i < nd_n:
        cs = cs * 131 + nd_kind[i]
        cs = cs * 131 + nd_a[i]
        cs = cs * 131 + nd_b[i]
        cs = cs * 131 + nd_c[i]
        if cs < 0:
            cs = 0 - cs
        cs = cs & 2147483647
        i = i + 1
    return cs


def _pyc_parse_main():
    _pyc_lex(_in_src)
    _pyc_parse(_in_mode)
    return _pyc_ast_checksum()
