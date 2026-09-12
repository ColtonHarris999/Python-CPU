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
