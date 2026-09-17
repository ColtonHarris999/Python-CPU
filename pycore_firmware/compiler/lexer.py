# Firmware lexer (compiler_design.md §5.5).
# Token kinds match CPython 3.14 ``token`` / ``tokenize.generate_tokens``.
# Derived from the CPython tokenizer state machine (PSF-2.0); rewritten as
# an index loop over a ``str`` with SoA arrays in ``_PYC_G``.


def _pyc_id_start(ch):
    return ch.isalpha() or ch == "_"


def _pyc_id_cont(ch):
    return ch.isalnum() or ch == "_"


def _pyc_is_hex(ch):
    return "0123456789abcdefABCDEF".find(ch) >= 0


def _pyc_is_oct(ch):
    return "01234567".find(ch) >= 0


def _pyc_is_bin(ch):
    return ch == "0" or ch == "1"


def _pyc_prefix_letters(s):
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if (
            ch == "r"
            or ch == "R"
            or ch == "b"
            or ch == "B"
            or ch == "u"
            or ch == "U"
            or ch == "f"
            or ch == "F"
            or ch == "t"
            or ch == "T"
        ):
            i = i + 1
        else:
            return 0
    return 1


def _pyc_prefix_has_ft(s):
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "f" or ch == "F" or ch == "t" or ch == "T":
            return 1
        i = i + 1
    return 0


def _pyc_str_prefix_ok(s):
    n = len(s)
    if n < 1:
        return 0
    if n > 2:
        return 0
    if _pyc_prefix_letters(s) == 0:
        return 0
    if _pyc_prefix_has_ft(s):
        return 0
    has_u = 0
    has_r = 0
    has_b = 0
    i = 0
    while i < n:
        ch = s[i]
        if ch == "u" or ch == "U":
            has_u = 1
        elif ch == "r" or ch == "R":
            has_r = 1
        elif ch == "b" or ch == "B":
            has_b = 1
        i = i + 1
    if has_u and has_r:
        return 0
    if has_u and has_b:
        return 0
    if n == 2:
        if has_r and has_b:
            return 1
        return 0
    return 1


def _pyc_lex_error(msg):
    raise SyntaxError(msg)


def _pyc_lex_ensure(need):
    global tk_a, tk_b, tk_s
    cap = len(tk_a)
    while cap < need:
        extra = cap
        if extra < 8:
            extra = 8
        tk_a = tk_a + ([0] * extra)
        tk_b = tk_b + ([0] * extra)
        tk_s = tk_s + ([0] * extra)
        cap = len(tk_a)


def _pyc_lex_emit(kind, line, col, start, end, text):
    global tk_a, tk_b, tk_s, tk_n
    _pyc_lex_ensure(tk_n + 1)
    packed_a = kind | (col << 8) | (line << 24)
    packed_b = start | (end << 32)
    tk_a[tk_n] = packed_a
    tk_b[tk_n] = packed_b
    tk_s[tk_n] = text
    tk_n = tk_n + 1


def _pyc_lex_nl():
    global _lex_i, _lex_line, _lex_col, _lex_line_start
    _lex_i = _lex_i + 1
    _lex_line = _lex_line + 1
    _lex_col = 0
    _lex_line_start = _lex_i


def _pyc_lex_op_len():
    i = _lex_i
    n = _lex_n
    src = _lex_src
    if i + 2 < n:
        w = src[i : i + 3]
        if w in OP3:
            return 3
    if i + 1 < n:
        w = src[i : i + 2]
        if w in OP2:
            return 2
    return 1


def _pyc_lex_read_string(quote, qlen, start, start_line, start_col):
    global _lex_i, _lex_line, _lex_col, _lex_line_start, _lex_src, _lex_n
    src = _lex_src
    n = _lex_n
    i = _lex_i
    line = _lex_line
    col = _lex_col
    i = i + qlen
    col = col + qlen
    while i < n:
        ch = src[i]
        if ch == "\\":
            i = i + 1
            col = col + 1
            if i >= n:
                _pyc_lex_error("unterminated string literal")
            if src[i] == "\n":
                i = i + 1
                line = line + 1
                col = 0
                _lex_line_start = i
            else:
                i = i + 1
                col = col + 1
            continue
        if qlen == 1 and ch == "\n":
            _pyc_lex_error("unterminated string literal")
        if ch == quote:
            if qlen == 1:
                i = i + 1
                col = col + 1
                text = src[start:i]
                _lex_i = i
                _lex_line = line
                _lex_col = col
                _pyc_lex_emit(TOK_STRING, start_line, start_col, start, i, text)
                return
            if i + 2 < n and src[i + 1] == quote and src[i + 2] == quote:
                i = i + 3
                col = col + 3
                text = src[start:i]
                _lex_i = i
                _lex_line = line
                _lex_col = col
                _pyc_lex_emit(TOK_STRING, start_line, start_col, start, i, text)
                return
        if ch == "\n":
            i = i + 1
            line = line + 1
            col = 0
            _lex_line_start = i
        else:
            i = i + 1
            col = col + 1
    if qlen == 3:
        _pyc_lex_error("EOF in multi-line string")
    _pyc_lex_error("unterminated string literal")


def _pyc_lex_read_prefixed_number(kind_ch):
    global _lex_i, _lex_col, _lex_src, _lex_n, _lex_line
    src = _lex_src
    n = _lex_n
    i = _lex_i
    start = i
    start_col = _lex_col
    start_line = _lex_line
    i = i + 2
    saw = 0
    while i < n:
        ch = src[i]
        ok = 0
        if kind_ch == "x":
            ok = _pyc_is_hex(ch)
        elif kind_ch == "o":
            ok = _pyc_is_oct(ch)
        else:
            ok = _pyc_is_bin(ch)
        if ok:
            saw = 1
            i = i + 1
        elif ch == "_":
            i = i + 1
        else:
            break
    if saw == 0:
        _pyc_lex_error("invalid numeric literal")
    if i > start + 2:
        last = src[i - 1]
        if last == "_":
            _pyc_lex_error("invalid numeric literal")
    text = src[start:i]
    _lex_col = start_col + (i - start)
    _lex_i = i
    _pyc_lex_emit(TOK_NUMBER, start_line, start_col, start, i, text)


def _pyc_lex_read_number():
    global _lex_i, _lex_col, _lex_src, _lex_n, _lex_line
    src = _lex_src
    n = _lex_n
    i = _lex_i
    start = i
    start_col = _lex_col
    start_line = _lex_line
    ch = src[i]
    if ch == "0" and i + 1 < n:
        nxt = src[i + 1]
        if nxt == "x" or nxt == "X":
            _pyc_lex_read_prefixed_number("x")
            return
        if nxt == "o" or nxt == "O":
            _pyc_lex_read_prefixed_number("o")
            return
        if nxt == "b" or nxt == "B":
            _pyc_lex_read_prefixed_number("b")
            return
    if ch == ".":
        i = i + 1
        while i < n and src[i].isdigit():
            i = i + 1
    else:
        while i < n:
            dch = src[i]
            if dch.isdigit():
                i = i + 1
            elif dch == "_":
                if i + 1 < n and src[i + 1].isdigit():
                    i = i + 1
                else:
                    _pyc_lex_error("invalid decimal literal")
            else:
                break
        if i < n and src[i] == ".":
            i = i + 1
            while i < n:
                dch = src[i]
                if dch.isdigit():
                    i = i + 1
                elif dch == "_":
                    if i + 1 < n and src[i + 1].isdigit():
                        i = i + 1
                    else:
                        _pyc_lex_error("invalid decimal literal")
                else:
                    break
    if i < n:
        ech = src[i]
        if ech == "e" or ech == "E":
            j = i + 1
            if j < n:
                sch = src[j]
                if sch == "+" or sch == "-":
                    j = j + 1
            if j < n and src[j].isdigit():
                i = j
                while i < n:
                    dch = src[i]
                    if dch.isdigit():
                        i = i + 1
                    elif dch == "_":
                        if i + 1 < n and src[i + 1].isdigit():
                            i = i + 1
                        else:
                            _pyc_lex_error("invalid decimal literal")
                    else:
                        break
            elif j > i + 1:
                _pyc_lex_error("invalid decimal literal")
    if i < n:
        jch = src[i]
        if jch == "j" or jch == "J":
            i = i + 1
    text = src[start:i]
    _lex_col = start_col + (i - start)
    _lex_i = i
    _pyc_lex_emit(TOK_NUMBER, start_line, start_col, start, i, text)


def _pyc_lex_read_name():
    global _lex_i, _lex_col, _lex_src, _lex_n, _lex_line, stmt_n, sc_n
    src = _lex_src
    n = _lex_n
    i = _lex_i
    start = i
    start_col = _lex_col
    start_line = _lex_line
    i = i + 1
    while i < n and _pyc_id_cont(src[i]):
        i = i + 1
    text = src[start:i]
    _lex_i = i
    _lex_col = start_col + (i - start)
    if i < n:
        q = src[i]
        if q == "'" or q == '"':
            if _pyc_prefix_letters(text):
                has_t = 0
                has_f = 0
                has_b = 0
                has_u = 0
                pi = 0
                pn = len(text)
                while pi < pn:
                    pch = text[pi]
                    if pch == "t" or pch == "T":
                        has_t = 1
                    elif pch == "f" or pch == "F":
                        has_f = 1
                    elif pch == "b" or pch == "B":
                        has_b = 1
                    elif pch == "u" or pch == "U":
                        has_u = 1
                    pi = pi + 1
                if has_t:
                    _pyc_lex_error("t-strings are not supported")
                if has_f:
                    if has_b:
                        _pyc_lex_error("invalid string prefix")
                    if has_u:
                        _pyc_lex_error("invalid string prefix")
                    if stmt_n == 2:
                        _pyc_lex_error("nested f-strings are not supported")
                    qlen = 1
                    if i + 2 < n and src[i + 1] == q and src[i + 2] == q:
                        qlen = 3
                    i = i + qlen
                    _lex_col = _lex_col + qlen
                    _lex_i = i
                    _pyc_lex_emit(
                        59, start_line, start_col, start, i, src[start:i]
                    )
                    stmt_n = 1
                    sc_n = qlen | (ord(q) << 8)
                    return
                if _pyc_str_prefix_ok(text) == 0:
                    _pyc_lex_error("invalid string prefix")
                qlen = 1
                if i + 2 < n and src[i + 1] == q and src[i + 2] == q:
                    qlen = 3
                _pyc_lex_read_string(q, qlen, start, start_line, start_col)
                return
    _pyc_lex_emit(TOK_NAME, start_line, start_col, start, i, text)


def _pyc_lex(src):
    global _lex_src, _lex_n, _lex_i, _lex_line, _lex_col, _lex_line_start
    global tk_a, tk_b, tk_s, tk_n, stmt_n, sc_n
    _lex_src = src
    _lex_n = len(src)
    _lex_i = 0
    _lex_line = 1
    _lex_col = 0
    _lex_line_start = 0
    tk_n = 0
    stmt_n = 0
    sc_n = 0
    cap = _lex_n // 4
    if cap < 8:
        cap = 8
    tk_a = [0] * cap
    tk_b = [0] * cap
    tk_s = [0] * cap
    paren = 0
    atbol = 1
    need_nl = 0
    indents = [0] * 64
    indent_n = 1
    n = _lex_n
    while 1:
        i = _lex_i
        if i >= n:
            if stmt_n != 0:
                _pyc_lex_error("unterminated f-string literal")
            if paren > 0:
                _pyc_lex_error("unexpected EOF in multi-line statement")
            if need_nl:
                _pyc_lex_emit(
                    TOK_NEWLINE,
                    _lex_line,
                    _lex_col,
                    i,
                    i + 1,
                    0,
                )
                need_nl = 0
                _lex_line = _lex_line + 1
                _lex_col = 0
            while indent_n > 1:
                indent_n = indent_n - 1
                _pyc_lex_emit(
                    TOK_DEDENT, _lex_line, _lex_col, i, i, 0
                )
            _pyc_lex_emit(TOK_ENDMARKER, _lex_line, _lex_col, i, i, 0)
            stmt_n = 0
            sc_n = 0
            return tk_n
        src = _lex_src
        if stmt_n == 1:
            qlen = sc_n & 255
            quote = chr((sc_n >> 8) & 255)
            start = i
            start_line = _lex_line
            start_col = _lex_col
            line = _lex_line
            col = _lex_col
            while i < n:
                ch = src[i]
                if qlen == 1 and ch == "\n":
                    _pyc_lex_error("unterminated f-string literal")
                if ch == quote:
                    closed = 0
                    if qlen == 1:
                        closed = 1
                    elif i + 2 < n:
                        if src[i + 1] == quote:
                            if src[i + 2] == quote:
                                closed = 1
                    if closed:
                        if i > start:
                            _pyc_lex_emit(
                                60,
                                start_line,
                                start_col,
                                start,
                                i,
                                src[start:i],
                            )
                        _pyc_lex_emit(
                            61, line, col, i, i + qlen, src[i : i + qlen]
                        )
                        i = i + qlen
                        col = col + qlen
                        _lex_i = i
                        _lex_line = line
                        _lex_col = col
                        stmt_n = 0
                        need_nl = 1
                        break
                if ch == "{":
                    if i + 1 < n:
                        if src[i + 1] == "{":
                            mid = src[start:i] + "{"
                            _pyc_lex_emit(
                                60, start_line, start_col, start, i + 1, mid
                            )
                            i = i + 2
                            col = col + 2
                            start = i
                            start_line = line
                            start_col = col
                            continue
                    if i > start:
                        _pyc_lex_emit(
                            60,
                            start_line,
                            start_col,
                            start,
                            i,
                            src[start:i],
                        )
                    _pyc_lex_emit(TOK_OP, line, col, i, i + 1, "{")
                    i = i + 1
                    col = col + 1
                    paren = paren + 1
                    _lex_i = i
                    _lex_line = line
                    _lex_col = col
                    stmt_n = 2
                    need_nl = 1
                    break
                if ch == "}":
                    if i + 1 < n:
                        if src[i + 1] == "}":
                            mid = src[start:i] + "}"
                            _pyc_lex_emit(
                                60, start_line, start_col, start, i + 1, mid
                            )
                            i = i + 2
                            col = col + 2
                            start = i
                            start_line = line
                            start_col = col
                            continue
                    _pyc_lex_error("f-string: single '}' is not allowed")
                if ch == "\n":
                    i = i + 1
                    line = line + 1
                    col = 0
                    _lex_line_start = i
                else:
                    i = i + 1
                    col = col + 1
            if stmt_n == 1:
                if i >= n:
                    _pyc_lex_error("unterminated f-string literal")
            continue
        if atbol:
            atbol = 0
            j = i
            vis = 0
            while j < n:
                c = src[j]
                if c == " ":
                    vis = vis + 1
                    j = j + 1
                elif c == "\t":
                    vis = (vis // 8 + 1) * 8
                    j = j + 1
                else:
                    break
            blank = 0
            if j >= n:
                blank = 1
            else:
                bc = src[j]
                if bc == "\n" or bc == "#":
                    blank = 1
            if blank:
                _lex_i = j
                _lex_col = j - _lex_line_start
                continue
            if paren == 0:
                top = indents[indent_n - 1]
                if vis > top:
                    if indent_n >= len(indents):
                        extra = len(indents)
                        indents = indents + ([0] * extra)
                    indents[indent_n] = vis
                    indent_n = indent_n + 1
                    _pyc_lex_emit(
                        TOK_INDENT,
                        _lex_line,
                        0,
                        _lex_line_start,
                        j,
                        src[_lex_line_start:j],
                    )
                elif vis < top:
                    while indent_n > 1 and indents[indent_n - 1] > vis:
                        indent_n = indent_n - 1
                        _pyc_lex_emit(
                            TOK_DEDENT, _lex_line, j - _lex_line_start, j, j, 0
                        )
                    if indents[indent_n - 1] != vis:
                        _pyc_lex_error(
                            "unindent does not match any outer indentation level"
                        )
            _lex_i = j
            _lex_col = j - _lex_line_start
            continue
        ch = src[i]
        if ch == " " or ch == "\t":
            _lex_i = i + 1
            _lex_col = _lex_col + 1
            continue
        if ch == "#":
            j = i
            while j < n and src[j] != "\n":
                j = j + 1
            _lex_col = _lex_col + (j - i)
            _lex_i = j
            continue
        if ch == "\n":
            if paren > 0:
                _pyc_lex_nl()
                atbol = 1
                continue
            if need_nl:
                _pyc_lex_emit(
                    TOK_NEWLINE, _lex_line, _lex_col, i, i + 1, 0
                )
                need_nl = 0
            _pyc_lex_nl()
            atbol = 1
            continue
        if ch == "\\":
            if i + 1 < n and src[i + 1] == "\n":
                _lex_i = i + 1
                _pyc_lex_nl()
                atbol = 0
                continue
            _pyc_lex_error("unexpected character after line continuation character")
        if ch == "'" or ch == '"':
            qlen = 1
            if i + 2 < n and src[i + 1] == ch and src[i + 2] == ch:
                qlen = 3
            _pyc_lex_read_string(ch, qlen, i, _lex_line, _lex_col)
            need_nl = 1
            continue
        if ch.isdigit() or (
            ch == "." and i + 1 < n and src[i + 1].isdigit()
        ):
            _pyc_lex_read_number()
            need_nl = 1
            continue
        if _pyc_id_start(ch):
            _pyc_lex_read_name()
            if stmt_n == 1:
                sc_n = sc_n | (paren << 16)
            need_nl = 1
            continue
        oplen = _pyc_lex_op_len()
        text = src[i : i + oplen]
        if text == "(" or text == "[" or text == "{":
            paren = paren + 1
        elif text == ")" or text == "]" or text == "}":
            if paren > 0:
                paren = paren - 1
            if stmt_n == 2:
                if text == "}":
                    pb = (sc_n >> 16) & 255
                    if paren == pb:
                        stmt_n = 1
        _pyc_lex_emit(TOK_OP, _lex_line, _lex_col, i, i + oplen, text)
        _lex_i = i + oplen
        _lex_col = _lex_col + oplen
        need_nl = 1


def _pyc_lex_main():
    return _pyc_lex(_in_src)
