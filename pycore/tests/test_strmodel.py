"""P5a string-accelerator spec model vs CPython 3.14.

The model is the golden for RTL. CPython is the semantic oracle for
concat/slice/search/char_at. Hash is FNV-1a (not CPython's salted hash).
"""

from __future__ import annotations

import unittest

from pycore.tools.encoding import (
    CTL_NONE,
    HEAP_BASE,
    HEAP_LIMIT,
    TAG_BOOL,
    TAG_CONTROL,
    TAG_INT,
    TAG_LONG_STR,
    TAG_SHORT_STR,
    VAL_MASK,
    decode_short_string,
    encode_short_string,
    make_control,
    stracc_content_hash,
    stracc_unpack_long_handle,
    SA_CONCAT,
    SA_REPEAT,
    SA_SLICE,
    SA_PAD,
    SA_CMP,
    SA_SEARCH,
    SA_HASH,
    SA_CHAR_AT,
    SA_ITER_NEXT,
    SA_REPLACE,
    SA_FIND,
    SA_RFIND,
    SA_COUNT,
    SA_CONTAINS,
    SA_STARTSWITH,
    SA_ENDSWITH,
    SA_PAD_BOTH,
    SA_JOIN,
    SA_TRIM,
    SA_TRIM_LEFT,
    SA_TRIM_RIGHT,
    SA_TRIM_BOTH,
    SA_CLASSIFY,
    SA_MAP,
    SA_AFFIX,
    SA_ZFILL,
    SA_IS_DIGIT,
    SA_IS_ASCII,
    SA_IS_LOWER,
    SA_IS_TITLE,
    SA_IS_ALPHA,
    SA_MAP_UPPER,
    SA_MAP_LOWER,
    SA_MAP_SWAPCASE,
    SA_MAP_CAPITALIZE,
    SA_MAP_TITLE,
    SA_MAP_CASEFOLD,
    SA_AFFIX_PREFIX,
    SA_AFFIX_SUFFIX,
)
from pycore.tools.strmodel import (
    StrAccel,
    TRAP_MEM_FAULT,
    TRAP_TYPE,
)


def _int(n: int) -> tuple[int, int]:
    return TAG_INT, n & VAL_MASK


def _short(s: str) -> tuple[int, int]:
    return TAG_SHORT_STR, encode_short_string(s.encode("latin-1"))


def _none() -> tuple[int, int]:
    return make_control(CTL_NONE)


class StrModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.accel = StrAccel()
        self.heap = HEAP_BASE

    def put(self, text: str) -> tuple[int, int]:
        entry, self.heap = self.accel.put(text, self.heap)
        return entry

    def run_op(self, op, var, a, b=(TAG_INT, 0), c=(TAG_CONTROL, CTL_NONE)):
        return self.accel.exec(op, var, a, b, c, self.heap)

    def text_of(self, entry: tuple[int, int]) -> str:
        tag, value = entry
        if tag == TAG_SHORT_STR:
            return decode_short_string(value).decode("latin-1")
        if tag == TAG_LONG_STR:
            return self.accel.read_str(entry)
        raise AssertionError(f"not a string tag={tag}")

    def test_empty_is_short(self) -> None:
        h = self.put("")
        self.assertEqual(h[0], TAG_SHORT_STR)
        self.assertEqual(decode_short_string(h[1]), b"")

    def test_15_ascii_is_short(self) -> None:
        s = "a" * 15
        h = self.put(s)
        self.assertEqual(h[0], TAG_SHORT_STR)
        self.assertEqual(decode_short_string(h[1]).decode("latin-1"), s)

    def test_16_ascii_is_long(self) -> None:
        s = "a" * 16
        h = self.put(s)
        self.assertEqual(h[0], TAG_LONG_STR)
        fields = stracc_unpack_long_handle(h[1])
        self.assertEqual(fields["kind"], 1)
        self.assertEqual(fields["nchars"], 16)
        self.assertEqual(fields["nbytes"], 16)
        self.assertEqual(self.accel.read_str(h), s)
        self.assertEqual(fields["hash"], stracc_content_hash(s.encode("latin-1")))

    def test_kind2_one_char_is_long(self) -> None:
        h = self.put("α")
        self.assertEqual(h[0], TAG_LONG_STR)
        self.assertEqual(stracc_unpack_long_handle(h[1])["kind"], 2)
        self.assertEqual(self.accel.read_str(h), "α")

    def test_kind4(self) -> None:
        h = self.put("🙂")
        self.assertEqual(h[0], TAG_LONG_STR)
        self.assertEqual(stracc_unpack_long_handle(h[1])["kind"], 4)
        self.assertEqual(self.accel.read_str(h), "🙂")

    def test_concat_empty_identity(self) -> None:
        h = self.put("hello")
        r = self.accel.exec(SA_CONCAT, 0, _short(""), h, _none(), self.heap)
        self.assertFalse(r.trap)
        self.assertEqual(self.text_of(r.entry), "hello")
        r2 = self.accel.exec(SA_CONCAT, 0, h, _short(""), _none(), self.heap)
        self.assertEqual(self.text_of(r2.entry), "hello")

    def test_concat_short_plus_short_stays_short(self) -> None:
        r = self.accel.exec(
            SA_CONCAT, 0, _short("hello"), _short(" world"), _none(), self.heap
        )
        self.assertFalse(r.trap)
        self.assertEqual(r.tag, TAG_SHORT_STR)
        self.assertEqual(decode_short_string(r.value).decode("latin-1"), "hello world")

    def test_concat_crosses_15(self) -> None:
        r = self.accel.exec(
            SA_CONCAT, 0, _short("abcdefghij"), _short("klmnop"), _none(), self.heap
        )
        self.assertEqual(r.tag, TAG_LONG_STR)
        self.assertEqual(self.text_of(r.entry), "abcdefghijklmnop")

    def test_concat_kind_promote(self) -> None:
        h1 = self.put("ab")
        h2 = self.put("α")
        r = self.accel.exec(SA_CONCAT, 0, h1, h2, _none(), self.heap)
        self.assertFalse(r.trap)
        self.assertEqual(self.text_of(r.entry), "abα")
        self.assertEqual(stracc_unpack_long_handle(r.value)["kind"], 2)

    def test_concat_matches_cpython(self) -> None:
        cases = [("foo", "bar"), ("", "x"), ("x" * 20, "y" * 5), ("café", "🙂")]
        for left, right in cases:
            with self.subTest(left=left, right=right):
                r = self.accel.exec(
                    SA_CONCAT, 0, self.put(left), self.put(right), _none(), self.heap
                )
                self.assertEqual(self.text_of(r.entry), left + right)

    def test_repeat_zero_is_empty(self) -> None:
        r = self.accel.exec(SA_REPEAT, 0, _short("ab"), _int(0), _none(), self.heap)
        self.assertEqual(decode_short_string(r.value), b"")

    def test_repeat_matches_cpython(self) -> None:
        for n in (1, 2, 8):
            r = self.accel.exec(SA_REPEAT, 0, _short("xy"), _int(n), _none(), self.heap)
            self.assertEqual(self.text_of(r.entry), "xy" * n)

    def test_slice_matches_cpython(self) -> None:
        s = "abcdefghij"
        h = self.put(s)
        cases = [(0, 3), (3, 8), (8, 3), (-2, None), (None, -1), (2, 2)]
        for start, stop in cases:
            b = _none() if start is None else _int(start)
            c = _none() if stop is None else _int(stop)
            r = self.accel.exec(SA_SLICE, 0, h, b, c, self.heap)
            self.assertEqual(self.text_of(r.entry), s[start:stop], (start, stop))

    def test_cmp_three_way(self) -> None:
        r = self.accel.exec(SA_CMP, 0, _short("abc"), _short("abd"), _none(), self.heap)
        self.assertEqual(r.tag, TAG_INT)
        self.assertEqual(r.signed_int(), -1)
        r = self.accel.exec(SA_CMP, 0, _short("abc"), _short("abc"), _none(), self.heap)
        self.assertEqual(r.signed_int(), 0)
        r = self.accel.exec(SA_CMP, 0, _short("abd"), _short("abc"), _none(), self.heap)
        self.assertEqual(r.signed_int(), 1)

    def test_cmp_kind_pairs_match_cpython(self) -> None:
        pairs = [("abc", "abc"), ("abc", "abd"), ("α", "a"), ("🙂", "α"), ("", "x")]
        for left, right in pairs:
            r = self.accel.exec(
                SA_CMP, 0, self.put(left), self.put(right), _none(), self.heap
            )
            expected = 0 if left == right else (-1 if left < right else 1)
            self.assertEqual(r.signed_int(), expected, (left, right))

    def test_search_find_rfind_count(self) -> None:
        hay = self.put("banana")
        needle = _short("ana")
        r = self.accel.exec(SA_SEARCH, SA_FIND, hay, needle, _none(), self.heap)
        self.assertEqual(r.signed_int(), 1)
        r = self.accel.exec(SA_SEARCH, SA_RFIND, hay, needle, _none(), self.heap)
        self.assertEqual(r.signed_int(), 3)
        r = self.accel.exec(SA_SEARCH, SA_COUNT, hay, needle, _none(), self.heap)
        self.assertEqual(r.signed_int(), "banana".count("ana"))

    def test_search_empty_needle(self) -> None:
        hay = _short("ab")
        empty = _short("")
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_FIND, hay, empty, _none(), self.heap).signed_int(),
            0,
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_RFIND, hay, empty, _none(), self.heap).signed_int(),
            2,
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_COUNT, hay, empty, _none(), self.heap).signed_int(),
            3,
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_CONTAINS, hay, empty, _none(), self.heap).value,
            1,
        )
        self.assertEqual(
            self.accel.exec(
                SA_SEARCH, SA_STARTSWITH, hay, empty, _none(), self.heap
            ).value,
            1,
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_ENDSWITH, hay, empty, _none(), self.heap).value,
            1,
        )

    def test_search_kind_reject(self) -> None:
        hay = self.put("abc")
        needle = self.put("α")
        r = self.accel.exec(SA_SEARCH, SA_FIND, hay, needle, _none(), self.heap)
        self.assertEqual(r.signed_int(), -1)
        r = self.accel.exec(SA_SEARCH, SA_CONTAINS, hay, needle, _none(), self.heap)
        self.assertEqual(r.tag, TAG_BOOL)
        self.assertEqual(r.value, 0)

    def test_search_matches_cpython(self) -> None:
        hay_s, needle_s = "mississippi", "iss"
        hay, needle = self.put(hay_s), self.put(needle_s)
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_FIND, hay, needle, _none(), self.heap).signed_int(),
            hay_s.find(needle_s),
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_RFIND, hay, needle, _none(), self.heap).signed_int(),
            hay_s.rfind(needle_s),
        )
        self.assertEqual(
            self.accel.exec(SA_SEARCH, SA_COUNT, hay, needle, _none(), self.heap).signed_int(),
            hay_s.count(needle_s),
        )

    def test_char_at(self) -> None:
        h = self.put("hello")
        r = self.accel.exec(SA_CHAR_AT, 0, h, _int(1), _none(), self.heap)
        self.assertEqual(decode_short_string(r.value).decode("latin-1"), "e")

    def test_char_at_oob(self) -> None:
        h = self.put("hi")
        r = self.accel.exec(SA_CHAR_AT, 0, h, _int(5), _none(), self.heap)
        self.assertTrue(r.trap)
        self.assertEqual(r.trap_code, TRAP_MEM_FAULT)

    def test_iter_next(self) -> None:
        h = self.put("ab")
        r = self.accel.exec(SA_ITER_NEXT, 0, h, _int(0), _none(), self.heap)
        self.assertEqual(decode_short_string(r.value).decode("latin-1"), "a")
        r = self.accel.exec(SA_ITER_NEXT, 0, h, _int(2), _none(), self.heap)
        self.assertEqual(r.tag, TAG_CONTROL)

    def test_hash_fnv(self) -> None:
        s = "hello"
        r = self.accel.exec(SA_HASH, 0, _short(s), _int(0), _none(), self.heap)
        self.assertEqual(r.value, stracc_content_hash(s.encode("latin-1")))

    def test_pad_center(self) -> None:
        r = self.accel.exec(
            SA_PAD, SA_PAD_BOTH, _short("ab"), _int(6), _none(), self.heap
        )
        self.assertEqual(self.text_of(r.entry), "  ab  ")

    def test_replace_short(self) -> None:
        hay = _short("banana")
        old = _short("ana")
        new = _short("XY")
        r = self.accel.exec(SA_REPLACE, 0, hay, old, new, self.heap)
        self.assertEqual(self.text_of(r.entry), "banana".replace("ana", "XY"))
        r = self.accel.exec(SA_REPLACE, 0, hay, _short("z"), _short("Q"), self.heap)
        self.assertEqual(self.text_of(r.entry), "banana")
        r = self.accel.exec(SA_REPLACE, 0, _short("abc"), _short(""), _short("-"), self.heap)
        self.assertEqual(self.text_of(r.entry), "abc".replace("", "-"))

    def test_type_error(self) -> None:
        r = self.accel.exec(SA_CONCAT, 0, _int(1), _short("x"), _none(), self.heap)
        self.assertTrue(r.trap)
        self.assertEqual(r.trap_code, TRAP_TYPE)

    def test_oom_does_not_move_heap(self) -> None:
        stuck = HEAP_LIMIT - 16
        r = self.accel.exec(
            SA_REPEAT, 0, _short("xy"), _int(10_000), _none(), stuck
        )
        self.assertTrue(r.trap)
        self.assertEqual(r.heap_ptr, stuck)
        self.assertEqual(r.trap_code, TRAP_MEM_FAULT)

    def test_identity_cmp_same_addr(self) -> None:
        h = self.put("a" * 20)
        r = self.accel.exec(SA_CMP, 0, h, h, _none(), self.heap)
        self.assertEqual(r.signed_int(), 0)

    def test_distinct_equal_long_cmp(self) -> None:
        a = self.put("a" * 20)
        b = self.put("a" * 20)
        self.assertNotEqual(
            stracc_unpack_long_handle(a[1])["addr"],
            stracc_unpack_long_handle(b[1])["addr"],
        )
        r = self.accel.exec(SA_CMP, 0, a, b, _none(), self.heap)
        self.assertEqual(r.signed_int(), 0)

    def test_trim_strip(self) -> None:
        r = self.run_op(SA_TRIM, SA_TRIM_BOTH, _short("  hi  "), _none())
        self.assertEqual(self.text_of(r.entry), "hi")
        r = self.run_op(SA_TRIM, SA_TRIM_LEFT, _short("  hi  "), _none())
        self.assertEqual(self.text_of(r.entry), "hi  ")
        r = self.run_op(SA_TRIM, SA_TRIM_RIGHT, _short("  hi  "), _none())
        self.assertEqual(self.text_of(r.entry), "  hi")
        r = self.run_op(SA_TRIM, SA_TRIM_BOTH, _short("xxhiyy"), _short("xy"))
        self.assertEqual(self.text_of(r.entry), "hi")
        r = self.run_op(SA_TRIM, SA_TRIM_BOTH, _short("already"), _none())
        self.assertEqual(self.text_of(r.entry), "already")

    def test_classify_latin1(self) -> None:
        r = self.run_op(SA_CLASSIFY, SA_IS_DIGIT, _short("12"), _none())
        self.assertEqual(r.tag, TAG_BOOL)
        self.assertEqual(r.value, 1)
        r = self.run_op(SA_CLASSIFY, SA_IS_DIGIT, _short("12a"), _none())
        self.assertEqual(r.value, 0)
        r = self.run_op(SA_CLASSIFY, SA_IS_ASCII, _short(""), _none())
        self.assertEqual(r.value, 1)
        r = self.run_op(SA_CLASSIFY, SA_IS_LOWER, _short("abc"), _none())
        self.assertEqual(r.value, 1)
        r = self.run_op(SA_CLASSIFY, SA_IS_LOWER, _short("123"), _none())
        self.assertEqual(r.value, 0)
        r = self.run_op(SA_CLASSIFY, SA_IS_TITLE, _short("Hello World"), _none())
        self.assertEqual(r.value, 1)
        greek = self.put("α")
        r = self.run_op(SA_CLASSIFY, SA_IS_ASCII, greek)
        self.assertEqual(r.value, 0)
        r = self.run_op(SA_CLASSIFY, SA_IS_ALPHA, greek)
        self.assertTrue(r.trap)

    def test_map_latin1(self) -> None:
        r = self.run_op(SA_MAP, SA_MAP_UPPER, _short("AbC"), _none())
        self.assertEqual(self.text_of(r.entry), "ABC")
        r = self.run_op(SA_MAP, SA_MAP_LOWER, _short("AbC"), _none())
        self.assertEqual(self.text_of(r.entry), "abc")
        r = self.run_op(SA_MAP, SA_MAP_SWAPCASE, _short("AbC"), _none())
        self.assertEqual(self.text_of(r.entry), "aBc")
        r = self.run_op(SA_MAP, SA_MAP_CAPITALIZE, _short("hELLO"), _none())
        self.assertEqual(self.text_of(r.entry), "Hello")
        r = self.run_op(SA_MAP, SA_MAP_TITLE, _short("hello world"), _none())
        self.assertEqual(self.text_of(r.entry), "Hello World")
        ss = self.put("ß")
        r = self.run_op(SA_MAP, SA_MAP_UPPER, ss)
        self.assertEqual(self.text_of(r.entry), "SS")
        r = self.run_op(SA_MAP, SA_MAP_TITLE, ss)
        self.assertEqual(self.text_of(r.entry), "Ss")
        r = self.run_op(SA_MAP, SA_MAP_CASEFOLD, ss)
        self.assertEqual(self.text_of(r.entry), "ss")
        mu = self.put("µ")
        r = self.run_op(SA_MAP, SA_MAP_UPPER, mu)
        self.assertEqual(self.text_of(r.entry), "µ".upper())
        greek = self.put("α")
        r = self.run_op(SA_MAP, SA_MAP_UPPER, greek)
        self.assertTrue(r.trap)

    def test_join_list(self) -> None:
        a = _short("a")
        b = _short("b")
        lst, self.heap = self.accel.plant_list([a, b], self.heap)
        r = self.accel.exec(SA_JOIN, 0, _short("-"), lst, _none(), self.heap)
        self.assertFalse(r.trap)
        self.assertEqual(self.text_of(r.entry), "a-b")
        empty, self.heap = self.accel.plant_list([], self.heap)
        r = self.accel.exec(SA_JOIN, 0, _short("-"), empty, _none(), self.heap)
        self.assertEqual(self.text_of(r.entry), "")
        one, self.heap = self.accel.plant_list([_short("only")], self.heap)
        r = self.accel.exec(SA_JOIN, 0, _short("-"), one, _none(), self.heap)
        self.assertEqual(self.text_of(r.entry), "only")

    def test_join_str(self) -> None:
        r = self.run_op(SA_JOIN, 0, _short("-"), _short("ab"))
        self.assertEqual(self.text_of(r.entry), "a-b")

    def test_affix_and_zfill(self) -> None:
        r = self.run_op(SA_AFFIX, SA_AFFIX_PREFIX, _short("foobar"), _short("foo"))
        self.assertEqual(self.text_of(r.entry), "bar")
        r = self.run_op(SA_AFFIX, SA_AFFIX_SUFFIX, _short("foobar"), _short("bar"))
        self.assertEqual(self.text_of(r.entry), "foo")
        r = self.run_op(SA_AFFIX, SA_AFFIX_PREFIX, _short("foobar"), _short("x"))
        self.assertEqual(self.text_of(r.entry), "foobar")
        r = self.run_op(SA_ZFILL, 0, _short("42"), _int(5))
        self.assertEqual(self.text_of(r.entry), "00042")
        r = self.run_op(SA_ZFILL, 0, _short("-42"), _int(5))
        self.assertEqual(self.text_of(r.entry), "-0042")


class TestImageAllocStr(unittest.TestCase):
    """P5b: HeapImageBuilder.alloc_str objects are readable by the spec model."""

    def test_short_and_long_roundtrip(self) -> None:
        from pycore.tools.heap_image import HeapImageBuilder
        from pycore.tools.strmodel import StrAccel

        img = HeapImageBuilder()
        short = img.alloc_str("hello")
        long_s = img.alloc_str("a" * 16)
        greek = img.alloc_str("α")
        self.assertEqual(short[0], TAG_SHORT_STR)
        self.assertEqual(long_s[0], TAG_LONG_STR)
        self.assertEqual(greek[0], TAG_LONG_STR)
        accel = StrAccel()
        accel.mem.words.update(img.words)
        self.assertEqual(accel.read_str(short), "hello")
        self.assertEqual(accel.read_str(long_s), "a" * 16)
        self.assertEqual(accel.read_str(greek), "α")

    def test_interned_long_reuses_addr(self) -> None:
        from pycore.tools.heap_image import HeapImageBuilder

        img = HeapImageBuilder()
        a = img.alloc_str("αβγ")
        b = img.alloc_str("αβγ")
        self.assertEqual(a, b)
        c = img.alloc_str("αβγ", interned=False)
        self.assertNotEqual(
            stracc_unpack_long_handle(a[1])["addr"],
            stracc_unpack_long_handle(c[1])["addr"],
        )


if __name__ == "__main__":
    unittest.main()
