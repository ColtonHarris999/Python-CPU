"""P5a differential harness: CPython 3.14 vs the STRACC spec model.

Corpus + seeded random (op, variant, operands). Hash is FNV-1a (model/RTL),
not CPython's salted hash — that field is compared model-vs-RTL only.

Usage:
  PYTHONPATH=pycore/tools python3 pycore/tools/strgen.py --seed 1 --n 400
"""

from __future__ import annotations

import argparse
import random
import sys

from encoding import (
    CTL_NONE,
    HEAP_BASE,
    TAG_BOOL,
    TAG_CONTROL,
    TAG_INT,
    TAG_LONG_STR,
    TAG_SHORT_STR,
    VAL_MASK,
    decode_short_string,
    encode_short_string,
    make_control,
    stracc_unpack_long_handle,
    SA_CHAR_AT,
    SA_CMP,
    SA_CONCAT,
    SA_CONTAINS,
    SA_COUNT,
    SA_ENDSWITH,
    SA_FIND,
    SA_HASH,
    SA_ITER_NEXT,
    SA_PAD,
    SA_PAD_BOTH,
    SA_PAD_LEFT,
    SA_PAD_RIGHT,
    SA_REPEAT,
    SA_RFIND,
    SA_SEARCH,
    SA_SLICE,
    SA_STARTSWITH,
    SA_JOIN,
    SA_TRIM,
    SA_CLASSIFY,
    SA_MAP,
    SA_AFFIX,
    SA_ZFILL,
    SA_EXPANDTABS,
    SA_SPLIT,
    SA_ORD,
    SA_CHR,
    SA_SPLIT_FWD,
    SA_SPLIT_REV,
    SA_SPLIT_LINES,
    SA_SPLIT_PARTITION,
    SA_SPLIT_RPARTITION,
    SA_TRIM_LEFT,
    SA_TRIM_RIGHT,
    SA_TRIM_BOTH,
    SA_IS_ALNUM,
    SA_IS_ALPHA,
    SA_IS_ASCII,
    SA_IS_DIGIT,
    SA_IS_LOWER,
    SA_IS_SPACE,
    SA_IS_UPPER,
    SA_IS_PRINTABLE,
    SA_IS_TITLE,
    SA_IS_DECIMAL,
    SA_IS_NUMERIC,
    SA_REPLACE,
    SA_MAP_UPPER,
    SA_MAP_LOWER,
    SA_MAP_SWAPCASE,
    SA_MAP_CAPITALIZE,
    SA_MAP_TITLE,
    SA_MAP_CASEFOLD,
    SA_AFFIX_PREFIX,
    SA_AFFIX_SUFFIX,
)
from strmodel import StrAccel

CORPUS = [
    "",
    "a",
    "ab",
    "hello",
    "hello world",
    "a" * 15,
    "a" * 16,
    "x" * 63,
    "y" * 64,
    "z" * 65,
    "banana",
    "mississippi",
    "ana",
    "iss",
    "  padded  ",
    "café",
    "α",
    "αβγ",
    "汉语",
    "🙂",
    "a🙂b",
    "AaBb",
    "\n\t ",
    "aaa",
    "ab" * 20,
    "12",
    "007",
    "²",      # SUPERSCRIPT TWO: numeric, not decimal
    "½",      # VULGAR FRACTION HALF: numeric, not decimal
    "٤",      # ARABIC-INDIC DIGIT FOUR: decimal
]


def _int(n: int) -> tuple[int, int]:
    return TAG_INT, n & VAL_MASK


def _none() -> tuple[int, int]:
    return make_control(CTL_NONE)


def _short(s: str) -> tuple[int, int]:
    return TAG_SHORT_STR, encode_short_string(s.encode("latin-1"))


def model_text(accel: StrAccel, entry: tuple[int, int]) -> str:
    tag, value = entry
    if tag == TAG_SHORT_STR:
        return decode_short_string(value).decode("latin-1")
    if tag == TAG_LONG_STR:
        return accel.read_str(entry)
    raise AssertionError(f"not a string tag={tag}")


def cpython_cmp(a: str, b: str) -> int:
    if a == b:
        return 0
    return -1 if a < b else 1


def classify(entry: tuple[int, int]) -> dict:
    tag, value = entry
    if tag == TAG_SHORT_STR:
        data = decode_short_string(value)
        return {
            "tag": tag,
            "nchars": len(data),
            "nbytes": len(data),
            "kind": 1,
            "short": True,
        }
    if tag == TAG_LONG_STR:
        h = stracc_unpack_long_handle(value)
        return {
            "tag": tag,
            "nchars": h["nchars"],
            "nbytes": h["nbytes"],
            "kind": h["kind"],
            "short": False,
            "hash": h["hash"],
        }
    return {"tag": tag, "value": value}


def run_case(rng: random.Random, accel: StrAccel, heap: int) -> int:
    """Run one random case. Returns the updated heap pointer."""
    a_s = rng.choice(CORPUS)
    b_s = rng.choice(CORPUS)
    op = rng.choice(
        [
            SA_CONCAT,
            SA_REPEAT,
            SA_SLICE,
            SA_PAD,
            SA_CMP,
            SA_SEARCH,
            SA_HASH,
            SA_CHAR_AT,
            SA_ITER_NEXT,
            SA_TRIM,
            SA_CLASSIFY,
            SA_MAP,
            SA_ZFILL,
            SA_AFFIX,
            SA_EXPANDTABS,
            SA_SPLIT,
            SA_ORD,
            SA_CHR,
            SA_REPLACE,
            SA_JOIN,
        ]
    )
    a_ent, heap = accel.put(a_s, heap)
    b_ent, heap = accel.put(b_s, heap)

    if op == SA_CONCAT:
        r = accel.exec(SA_CONCAT, 0, a_ent, b_ent, _none(), heap)
        assert not r.trap, "concat trap"
        got = model_text(accel, r.entry)
        assert got == a_s + b_s, (a_s, b_s, got)
        heap = r.heap_ptr
    elif op == SA_REPEAT:
        n = rng.choice([0, 1, 2, 3, 4, -1])
        r = accel.exec(SA_REPEAT, 0, a_ent, _int(n), _none(), heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        assert got == a_s * max(n, 0), (a_s, n, got)
        heap = r.heap_ptr
    elif op == SA_SLICE:
        start = rng.choice([None, 0, 1, 2, -1, -2, 8, 50])
        stop = rng.choice([None, 0, 1, 3, -1, 8, 50])
        b = _none() if start is None else _int(start)
        c = _none() if stop is None else _int(stop)
        r = accel.exec(SA_SLICE, 0, a_ent, b, c, heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        assert got == a_s[start:stop], (a_s, start, stop, got)
        heap = r.heap_ptr
    elif op == SA_PAD:
        width = rng.choice([0, 1, 4, 8, 20, len(a_s)])
        var = rng.choice([SA_PAD_LEFT, SA_PAD_RIGHT, SA_PAD_BOTH])
        r = accel.exec(SA_PAD, var, a_ent, _int(width), _none(), heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        if var == SA_PAD_LEFT:
            exp = a_s.rjust(width)
        elif var == SA_PAD_RIGHT:
            exp = a_s.ljust(width)
        else:
            exp = a_s.center(width)
        assert got == exp, (a_s, width, var, got, exp)
        heap = r.heap_ptr
    elif op == SA_CMP:
        r = accel.exec(SA_CMP, 0, a_ent, b_ent, _none(), heap)
        assert not r.trap
        assert r.tag == TAG_INT
        assert r.signed_int() == cpython_cmp(a_s, b_s), (a_s, b_s, r.signed_int())
    elif op == SA_SEARCH:
        var = rng.choice(
            [SA_FIND, SA_RFIND, SA_COUNT, SA_CONTAINS, SA_STARTSWITH, SA_ENDSWITH]
        )
        r = accel.exec(SA_SEARCH, var, a_ent, b_ent, _none(), heap)
        assert not r.trap
        if var == SA_FIND:
            assert r.signed_int() == a_s.find(b_s), (a_s, b_s, r.signed_int())
        elif var == SA_RFIND:
            assert r.signed_int() == a_s.rfind(b_s)
        elif var == SA_COUNT:
            assert r.signed_int() == a_s.count(b_s)
        elif var == SA_CONTAINS:
            assert r.tag == TAG_BOOL
            assert bool(r.value) == (b_s in a_s)
        elif var == SA_STARTSWITH:
            assert bool(r.value) == a_s.startswith(b_s)
        else:
            assert bool(r.value) == a_s.endswith(b_s)
    elif op == SA_HASH:
        r = accel.exec(SA_HASH, 0, a_ent, _int(0), _none(), heap)
        assert not r.trap and r.tag == TAG_INT
        info = classify(a_ent)
        if not info.get("short"):
            assert (r.value & 0xFFFFFFFF) == info["hash"]
    elif op == SA_CHAR_AT:
        if not a_s:
            r = accel.exec(SA_CHAR_AT, 0, a_ent, _int(0), _none(), heap)
            assert r.trap
        else:
            i = rng.randrange(len(a_s))
            r = accel.exec(SA_CHAR_AT, 0, a_ent, _int(i), _none(), heap)
            assert not r.trap
            assert model_text(accel, r.entry) == a_s[i]
            heap = r.heap_ptr
    elif op == SA_ITER_NEXT:
        r = accel.exec(SA_ITER_NEXT, 0, a_ent, _int(len(a_s)), _none(), heap)
        assert not r.trap and r.tag == TAG_CONTROL
        if a_s:
            r = accel.exec(SA_ITER_NEXT, 0, a_ent, _int(0), _none(), heap)
            assert model_text(accel, r.entry) == a_s[0]
            heap = r.heap_ptr
    elif op == SA_TRIM:
        var = rng.choice([SA_TRIM_LEFT, SA_TRIM_RIGHT, SA_TRIM_BOTH])
        use_cs = rng.choice([False, True])
        cs = b_s if use_cs else None
        r = accel.exec(
            SA_TRIM, var, a_ent, b_ent if use_cs else _none(), _none(), heap
        )
        assert not r.trap, (a_s, cs, var)
        got = model_text(accel, r.entry)
        if var == SA_TRIM_LEFT:
            exp = a_s.lstrip(cs)
        elif var == SA_TRIM_RIGHT:
            exp = a_s.rstrip(cs)
        else:
            exp = a_s.strip(cs)
        assert got == exp, (a_s, cs, var, got, exp)
        heap = r.heap_ptr
    elif op == SA_CLASSIFY:
        var = rng.choice(
            [
                SA_IS_ALNUM,
                SA_IS_ALPHA,
                SA_IS_ASCII,
                SA_IS_DIGIT,
                SA_IS_LOWER,
                SA_IS_SPACE,
                SA_IS_UPPER,
                SA_IS_PRINTABLE,
                SA_IS_TITLE,
                SA_IS_DECIMAL,
                SA_IS_NUMERIC,
            ]
        )
        r = accel.exec(SA_CLASSIFY, var, a_ent, _none(), _none(), heap)
        if any(ord(c) > 255 for c in a_s) and var != SA_IS_ASCII:
            assert r.trap
        else:
            assert not r.trap
            meth = {
                SA_IS_ALNUM: str.isalnum,
                SA_IS_ALPHA: str.isalpha,
                SA_IS_ASCII: str.isascii,
                SA_IS_DIGIT: str.isdigit,
                SA_IS_LOWER: str.islower,
                SA_IS_SPACE: str.isspace,
                SA_IS_UPPER: str.isupper,
                SA_IS_PRINTABLE: str.isprintable,
                SA_IS_TITLE: str.istitle,
                SA_IS_DECIMAL: str.isdecimal,
                SA_IS_NUMERIC: str.isnumeric,
            }[var]
            assert bool(r.value) == meth(a_s), (a_s, var, r.value)
    elif op == SA_MAP:
        var = rng.choice(
            [
                SA_MAP_UPPER,
                SA_MAP_LOWER,
                SA_MAP_SWAPCASE,
                SA_MAP_CAPITALIZE,
                SA_MAP_TITLE,
                SA_MAP_CASEFOLD,
            ]
        )
        r = accel.exec(SA_MAP, var, a_ent, _none(), _none(), heap)
        if any(ord(c) > 255 for c in a_s):
            assert r.trap, a_s
        else:
            assert not r.trap
            meth = {
                SA_MAP_UPPER: str.upper,
                SA_MAP_LOWER: str.lower,
                SA_MAP_SWAPCASE: str.swapcase,
                SA_MAP_CAPITALIZE: str.capitalize,
                SA_MAP_TITLE: str.title,
                SA_MAP_CASEFOLD: str.casefold,
            }[var]
            got = model_text(accel, r.entry)
            assert got == meth(a_s), (a_s, var, got, meth(a_s))
            heap = r.heap_ptr
    elif op == SA_ZFILL:
        width = rng.choice([0, 1, 4, 8, 20, len(a_s)])
        r = accel.exec(SA_ZFILL, 0, a_ent, _int(width), _none(), heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        assert got == a_s.zfill(width), (a_s, width, got)
        heap = r.heap_ptr
    elif op == SA_AFFIX:
        var = rng.choice([SA_AFFIX_PREFIX, SA_AFFIX_SUFFIX])
        r = accel.exec(SA_AFFIX, var, a_ent, b_ent, _none(), heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        exp = a_s.removeprefix(b_s) if var == SA_AFFIX_PREFIX else a_s.removesuffix(b_s)
        assert got == exp, (a_s, b_s, var, got, exp)
        heap = r.heap_ptr
    elif op == SA_EXPANDTABS:
        tabsize = rng.choice([0, 1, 4, 8, 16, -1])
        r = accel.exec(SA_EXPANDTABS, 0, a_ent, _int(tabsize), _none(), heap)
        assert not r.trap
        got = model_text(accel, r.entry)
        assert got == a_s.expandtabs(tabsize), (a_s, tabsize, got)
        heap = r.heap_ptr
    elif op == SA_SPLIT:
        var = rng.choice(
            [
                SA_SPLIT_FWD,
                SA_SPLIT_REV,
                SA_SPLIT_LINES,
                SA_SPLIT_PARTITION,
                SA_SPLIT_RPARTITION,
            ]
        )
        if var in (SA_SPLIT_PARTITION, SA_SPLIT_RPARTITION):
            if not b_s:
                r = accel.exec(SA_SPLIT, var, a_ent, b_ent, _none(), heap)
                assert r.trap
            else:
                r = accel.exec(SA_SPLIT, var, a_ent, b_ent, _none(), heap)
                assert not r.trap
                got = [model_text(accel, e) for e in accel._seq_entries(r.entry)]
                exp = list(
                    a_s.rpartition(b_s) if var == SA_SPLIT_RPARTITION else a_s.partition(b_s)
                )
                assert got == exp, (a_s, b_s, var, got, exp)
                heap = r.heap_ptr
        elif var == SA_SPLIT_LINES:
            keep = rng.choice([False, True])
            r = accel.exec(SA_SPLIT, var, a_ent, _int(int(keep)), _none(), heap)
            assert not r.trap
            got = [model_text(accel, e) for e in accel._seq_entries(r.entry)]
            assert got == a_s.splitlines(keep), (a_s, keep, got)
            heap = r.heap_ptr
        else:
            use_sep = rng.choice([False, True])
            mx = rng.choice([-1, 0, 1, 2, 8])
            if use_sep and not b_s:
                r = accel.exec(SA_SPLIT, var, a_ent, b_ent, _int(mx), heap)
                assert r.trap
            elif use_sep:
                r = accel.exec(SA_SPLIT, var, a_ent, b_ent, _int(mx), heap)
                assert not r.trap
                got = [model_text(accel, e) for e in accel._seq_entries(r.entry)]
                exp = a_s.rsplit(b_s, mx) if var == SA_SPLIT_REV else a_s.split(b_s, mx)
                assert got == exp, (a_s, b_s, mx, var, got, exp)
                heap = r.heap_ptr
            else:
                r = accel.exec(SA_SPLIT, var, a_ent, _none(), _int(mx), heap)
                assert not r.trap
                got = [model_text(accel, e) for e in accel._seq_entries(r.entry)]
                exp = a_s.rsplit(None, mx) if var == SA_SPLIT_REV else a_s.split(None, mx)
                assert got == exp, (a_s, mx, var, got, exp)
                heap = r.heap_ptr
    elif op == SA_ORD:
        r = accel.exec(SA_ORD, 0, a_ent, _none(), _none(), heap)
        if len(a_s) != 1:
            assert r.trap, (a_s,)
        else:
            assert not r.trap and r.signed_int() == ord(a_s), (a_s, r.signed_int())
    elif op == SA_CHR:
        cp = rng.choice([0, 65, 233, 0x03B1, 0xD800, 0x1F600, 0x10FFFF, 0x110000, -1])
        r = accel.exec(SA_CHR, 0, _int(cp), _none(), _none(), heap)
        if cp < 0 or cp > 0x10FFFF:
            assert r.trap, (cp,)
        else:
            assert not r.trap
            assert model_text(accel, r.entry) == chr(cp), (cp,)
            heap = r.heap_ptr
    elif op == SA_REPLACE:
        old_s = rng.choice(CORPUS)
        new_s = rng.choice(CORPUS)
        old_e, heap = accel.put(old_s, heap)
        new_e, heap = accel.put(new_s, heap)
        r = accel.exec(SA_REPLACE, 0, a_ent, old_e, new_e, heap)
        assert not r.trap, ("replace trap", a_s, old_s, new_s)
        got = model_text(accel, r.entry)
        assert got == a_s.replace(old_s, new_s), (a_s, old_s, new_s, got)
        heap = r.heap_ptr
    elif op == SA_JOIN:
        parts = [rng.choice(CORPUS) for _ in range(rng.randint(0, 4))]
        ents = []
        for part in parts:
            e, heap = accel.put(part, heap)
            ents.append(e)
        lst, heap = accel.plant_list(ents, heap)
        r = accel.exec(SA_JOIN, 0, a_ent, lst, _none(), heap)
        assert not r.trap, ("join trap", a_s, parts)
        got = model_text(accel, r.entry)
        assert got == a_s.join(parts), (a_s, parts, got)
        heap = r.heap_ptr
    return heap


def directed_kind_pairs(accel: StrAccel, heap: int) -> int:
    kinds = ["ascii", "α", "🙂"]
    lefts = ["ab", "αβ", "🙂x"]
    rights = ["cd", "γ", "🙂"]
    for a_s in lefts:
        for b_s in rights:
            a_ent, heap = accel.put(a_s, heap)
            b_ent, heap = accel.put(b_s, heap)
            r = accel.exec(SA_CONCAT, 0, a_ent, b_ent, _none(), heap)
            assert model_text(accel, r.entry) == a_s + b_s
            heap = r.heap_ptr
            r = accel.exec(SA_CMP, 0, a_ent, b_ent, _none(), heap)
            assert r.signed_int() == cpython_cmp(a_s, b_s)
            r = accel.exec(SA_SEARCH, SA_FIND, a_ent, b_ent, _none(), heap)
            assert r.signed_int() == a_s.find(b_s)
    _ = kinds
    return heap


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--n", type=int, default=400)
    args = p.parse_args(argv)
    rng = random.Random(args.seed)
    accel = StrAccel()
    heap = HEAP_BASE
    heap = directed_kind_pairs(accel, heap)
    for i in range(args.n):
        try:
            heap = run_case(rng, accel, heap)
        except AssertionError as exc:
            print(f"FAIL seed={args.seed} case={i}: {exc}", file=sys.stderr)
            return 1
    print(f"PASS seed={args.seed} n={args.n} directed_kind_pairs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
