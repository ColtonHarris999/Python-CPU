"""Unit tests for ROM firmware builtin seeding into the boot builtins dict."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("ROM firmware seed tests require Python 3.14")

from encoding import TAG_CODE_OBJECT
from pycore.tools import image_from_source

WAVE3_NAMES = {
    "divmod",
    "pow",
    "round",
    "bin",
    "hex",
    "oct",
    "tuple",
    "min",
    "list",
    "dict",
    "reversed",
    "filter",
    "sorted",
}

WAVE4_ATTR_NAMES = {
    "hasattr",
    "getattr",
    "setattr",
    "delattr",
    "isinstance",
    "issubclass",
}

WAVE4_PRINT_NAMES = {
    "print",
}


def _load_firmware(name: str):
    path = image_from_source.FIRMWARE_BUILTINS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Device-native tag probe (OBK_BUILTIN) that ROM bodies LOAD_GLOBAL.
    mod.__dict__["_bi_code_kind"] = image_from_source._host_code_kind
    spec.loader.exec_module(mod)
    return getattr(mod, name)


def _same_float(a: float, b: float) -> bool:
    import math
    import struct

    if math.isnan(a) and math.isnan(b):
        return True
    return struct.pack("<d", a) == struct.pack("<d", b)


class RomFirmwareSeedTest(unittest.TestCase):
    def test_registry_sources_validate(self) -> None:
        for dict_key, stem, func_name in image_from_source.ROM_FIRMWARE_BUILTINS:
            path = image_from_source.FIRMWARE_BUILTINS_DIR / f"{stem}.py"
            self.assertTrue(path.is_file(), f"missing firmware source {path}")
            source = path.read_text(encoding="utf-8")
            ns: dict[str, object] = {}
            exec(compile(source, str(path), "exec"), ns)
            func = ns[func_name]
            image_from_source.validate_code_tree(func.__code__)
            self.assertEqual(dict_key, func_name)

    def test_wave3_names_present(self) -> None:
        keys = {k for k, _, _ in image_from_source.ROM_FIRMWARE_BUILTINS}
        self.assertTrue(WAVE3_NAMES.issubset(keys), keys)
        self.assertTrue(WAVE4_ATTR_NAMES.issubset(keys), keys)
        self.assertTrue(WAVE4_PRINT_NAMES.issubset(keys), keys)
        self.assertIn("compile", keys)
        self.assertIn("eval", keys)
        self.assertIn("exec", keys)
        self.assertIn("bios", keys)
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 31)

    def test_seed_firmware_function_returns_code_object(self) -> None:
        serializer = image_from_source._ImageSerializer()
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "sum.py"
        handle = image_from_source.seed_firmware_function(serializer, path, "sum")
        self.assertEqual(handle[0], TAG_CODE_OBJECT)
        self.assertGreater(len(serializer.program_slots), 0)
        self.assertTrue(any(v == (0,) for v in serializer.defaults_map.values()))

    def test_sorted_defaults_include_reverse(self) -> None:
        serializer = image_from_source._ImageSerializer()
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "sorted.py"
        handle = image_from_source.seed_firmware_function(serializer, path, "sorted")
        self.assertEqual(handle[0], TAG_CODE_OBJECT)
        self.assertTrue(any(v == (False,) for v in serializer.defaults_map.values()))

    def test_seed_rom_firmware_builtins_all_code_objects(self) -> None:
        pairs = image_from_source.seed_rom_firmware_builtins(
            image_from_source._ImageSerializer()
        )
        self.assertEqual(len(pairs), len(image_from_source.ROM_FIRMWARE_BUILTINS))
        for _name, handle in pairs:
            self.assertEqual(handle[0], TAG_CODE_OBJECT)

    def test_build_image_includes_rom_firmware_code(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "def managed_entry():\n"
            "    return sum(range(3))\n"
            "\n"
            "managed_entry()\n",
            "<rom-seed>",
        )
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)
        self.assertGreaterEqual(
            len(result.code_handles),
            2 + len(image_from_source.ROM_FIRMWARE_BUILTINS),
        )
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 31)
        self.assertGreater(len(result.program_slots), 0)

    def test_print_seed_has_kwdefaults_and_varargs(self) -> None:
        import types

        serializer = image_from_source._ImageSerializer()
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "print.py"
        ns: dict[str, object] = {}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        print_fn = ns["print"]
        assert isinstance(print_fn, types.FunctionType)
        co = print_fn.__code__
        self.assertTrue(co.co_flags & 0x04)  # CO_VARARGS
        self.assertEqual(co.co_kwonlyargcount, 2)
        self.assertEqual(print_fn.__kwdefaults__, {"sep": " ", "end": "\n"})
        self.assertIn("_bi_print", co.co_names)
        # seed_firmware_function re-execs; assert the map gets kwdefaults.
        handle = image_from_source.seed_firmware_function(serializer, path, "print")
        self.assertEqual(handle[0], TAG_CODE_OBJECT)
        self.assertEqual(len(serializer.kwdefaults_map), 1)
        self.assertEqual(
            next(iter(serializer.kwdefaults_map.values())),
            {"sep": " ", "end": "\n"},
        )

    def test_stopiteration_seeded_and_sidecared(self) -> None:
        from encoding import (
            CTL_NONE,
            ITER_EXHAUST_TYPE_ADDR,
            MUT_DICT,
            OBK_TYPE,
            TAG_MUT_COLLEC,
            TAG_OBJECT,
            is_mut_kind,
            ob_kind,
            obj_field_tag_addr,
            obj_field_val_addr,
        )

        serializer = image_from_source._ImageSerializer()
        builtins = image_from_source.build_builtins_dict(serializer)
        self.assertEqual(builtins[0], TAG_MUT_COLLEC)
        self.assertTrue(is_mut_kind(builtins, MUT_DICT))
        words = serializer.heap.words
        self.assertIn(ITER_EXHAUST_TYPE_ADDR, words)
        self.assertEqual(words[ITER_EXHAUST_TYPE_ADDR + 16] & 0xF, TAG_OBJECT)
        type_addr = words[ITER_EXHAUST_TYPE_ADDR] & ((1 << 64) - 1)
        self.assertEqual(ob_kind(words[type_addr]), OBK_TYPE)
        # Relinked: field1 is Exception (OBJECT), not None.
        self.assertEqual(
            words[obj_field_tag_addr(type_addr, 1)] & 0xF, TAG_OBJECT
        )
        self.assertNotEqual(
            words[obj_field_val_addr(type_addr, 1)] & 0xF, CTL_NONE
        )

    def test_memoryerror_singleton_is_conditional_and_sidecared(self) -> None:
        from encoding import (
            MEMORY_ERROR_INSTANCE_ADDR,
            OBK_EXCEPTION,
            OBK_TYPE,
            TAG_OBJECT,
            ob_kind,
            obj_field_tag_addr,
            obj_field_val_addr,
        )

        plain = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(plain)
        self.assertNotIn(MEMORY_ERROR_INSTANCE_ADDR, plain.heap.words)

        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer, memory_error=True)
        words = serializer.heap.words
        self.assertEqual(words[MEMORY_ERROR_INSTANCE_ADDR + 16] & 0xF, TAG_OBJECT)
        instance = words[MEMORY_ERROR_INSTANCE_ADDR] & ((1 << 64) - 1)
        self.assertEqual(ob_kind(words[instance]), OBK_EXCEPTION)
        self.assertEqual(words[obj_field_tag_addr(instance, 0)] & 0xF, TAG_OBJECT)
        exc_type = words[obj_field_val_addr(instance, 0)] & ((1 << 64) - 1)
        self.assertEqual(ob_kind(words[exc_type]), OBK_TYPE)

    def test_bi_print_seeded_as_native_builtin(self) -> None:
        from encoding import (
            BI_PRINT,
            OBK_BUILTIN,
            TAG_CODE_OBJECT,
            int_value,
            ob_kind,
            obj_field_val_addr,
        )

        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer)
        # Public print is ROM; native sink must appear as OBK_BUILTIN(BI_PRINT).
        rom_keys = {k for k, _, _ in image_from_source.ROM_FIRMWARE_BUILTINS}
        self.assertIn("print", rom_keys)
        self.assertNotIn("_bi_print", rom_keys)
        found_sink = False
        words = serializer.heap.words
        for addr, head in words.items():
            if ob_kind(head) != OBK_BUILTIN:
                continue
            if words.get(obj_field_val_addr(addr, 0)) == int_value(BI_PRINT):
                found_sink = True
                break
        self.assertTrue(found_sink, "OBK_BUILTIN(BI_PRINT) not in builtins heap")
        rom_pairs = image_from_source.seed_rom_firmware_builtins(
            image_from_source._ImageSerializer()
        )
        self.assertTrue(any(h[0] == TAG_CODE_OBJECT for _, h in rom_pairs))

    def test_int_type_flagged_for_call_convert(self) -> None:
        from encoding import (
            OB_FLAG_INT_TYPE,
            OBK_TYPE,
            ob_flags,
            ob_kind,
        )

        self.assertEqual(OB_FLAG_INT_TYPE, 2)
        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer)
        found = False
        for addr, head in serializer.heap.words.items():
            if ob_kind(head) != OBK_TYPE:
                continue
            if ob_flags(head) & OB_FLAG_INT_TYPE:
                found = True
                self.assertEqual(ob_flags(head) & OB_FLAG_INT_TYPE, OB_FLAG_INT_TYPE)
                break
        self.assertTrue(found, "OBK_TYPE with OB_FLAG_INT_TYPE missing from builtins heap")

    def test_str_type_flagged_for_call_convert(self) -> None:
        from encoding import (
            OB_FLAG_STR_TYPE,
            OBK_TYPE,
            ob_flags,
            ob_kind,
        )

        self.assertEqual(OB_FLAG_STR_TYPE, 4)
        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer)
        found = False
        for addr, head in serializer.heap.words.items():
            if ob_kind(head) != OBK_TYPE:
                continue
            if ob_flags(head) & OB_FLAG_STR_TYPE:
                found = True
                self.assertEqual(ob_flags(head) & OB_FLAG_STR_TYPE, OB_FLAG_STR_TYPE)
                break
        self.assertTrue(found, "OBK_TYPE with OB_FLAG_STR_TYPE missing from builtins heap")

    def test_rom_bodies_are_cache_free_and_jumps_remap(self) -> None:
        """strip_inline_caches keeps every instruction, arg and jump target."""
        import dis
        import opcode

        def decode(code: bytes):
            unit = 0
            out = []
            while unit < len(code) // 2:
                start = unit
                arg = 0
                while code[2 * unit] == image_from_source.OP_EXTENDED_ARG:
                    arg = (arg | code[2 * unit + 1]) << 8
                    unit += 1
                op = code[2 * unit]
                arg |= code[2 * unit + 1]
                out.append((start, unit, opcode.opname[op], arg))
                unit += 1
            return out

        def parse_exc(table: bytes):
            pos = 0

            def varint():
                nonlocal pos
                b = table[pos]
                pos += 1
                v = b & 0x3F
                while b & 0x40:
                    b = table[pos]
                    pos += 1
                    v = (v << 6) | (b & 0x3F)
                return v

            out = []
            while pos < len(table):
                s = varint()
                n = varint()
                t = varint()
                dl = varint()
                out.append((s, s + n, t, dl >> 1, dl & 1))
            return out

        entries = list(image_from_source.ROM_FIRMWARE_BUILTINS) + [
            (str(i), stem, fn) for i, stem, fn in image_from_source.ROM_NATIVE_METHODS
        ]
        total_old = total_new = 0
        exc_tables_seen = 0
        pads = 0
        for _key, stem, func_name in entries:
            path = image_from_source.FIRMWARE_BUILTINS_DIR / f"{stem}.py"
            ns: dict[str, object] = {}
            exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
            co = ns[func_name].__code__
            if func_name == "set_add":
                co = image_from_source._build_set_add_method_code(co)
            co = image_from_source.fold_slice_constants_one(co)
            code, table = image_from_source.strip_inline_caches(co)
            total_old += len(co.co_code) // 2
            total_new += len(code) // 2
            old = [i for i in dis.get_instructions(co) if i.opname != "EXTENDED_ARG"]
            ordinal = {i.start_offset // 2: n for n, i in enumerate(old)}
            new = decode(code)
            # A NOP kept after a CALL that ends a protected range is padding
            # (strip_inline_caches), not an instruction of the source body.
            kept = []
            for n, ins in enumerate(new):
                if (
                    ins[2] == "NOP"
                    and n > 0
                    and new[n - 1][2] in image_from_source._CALL_OPS
                    and old[len(kept)].opname != "NOP"
                ):
                    pads += 1
                    continue
                kept.append(ins)
            new = kept
            new_ordinal = {start: n for n, (start, _pc, _name, _arg) in enumerate(new)}
            with self.subTest(body=func_name):
                self.assertEqual(len(new), len(old))
                self.assertNotIn("CACHE", {name for _s, _p, name, _a in new})
                for (start, pc, name, arg), ins in zip(new, old):
                    self.assertEqual(name, ins.opname)
                    if name in image_from_source._REL_JUMP_OPS:
                        n_cache = opcode._inline_cache_entries.get(name, 0)
                        if name in image_from_source._BACKWARD_JUMP_OPS:
                            target = pc + 1 + n_cache - arg
                        else:
                            target = pc + 1 + n_cache + arg
                        self.assertEqual(new_ordinal[target], ordinal[ins.argval // 2])
                    elif ins.arg is not None:
                        self.assertEqual(arg, ins.arg)
                old_exc = dis._parse_exception_table(co)
                new_exc = parse_exc(table)
                self.assertEqual(len(new_exc), len(old_exc))
                for a, b in zip(old_exc, new_exc):
                    exc_tables_seen += 1
                    self.assertEqual(new_ordinal[b[0]], ordinal[a.start // 2])
                    self.assertEqual(new_ordinal[b[2]], ordinal[a.target // 2])
                    self.assertEqual((b[3], bool(b[4])), (a.depth, a.lasti))
                    if a.end // 2 == len(co.co_code) // 2:
                        self.assertEqual(b[1], len(code) // 2)
                    else:
                        self.assertEqual(new_ordinal[b[1]], ordinal[a.end // 2])
        self.assertGreater(exc_tables_seen, 0, "no ROM body with a try block")
        self.assertGreater(pads, 0, "compile's `try: return f()` needs a pad NOP")
        self.assertLess(total_new, total_old * 0.7, (total_new, total_old))

    def test_wave3_image_programs_build(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for name in (
            "img_firmware_wave3a.py",
            "img_firmware_wave3_strings.py",
            "img_firmware_wave3_pow.py",
            "img_firmware_wave3_containers.py",
            "img_firmware_sorted_kw.py",
            "img_firmware_filter_pred.py",
            "img_firmware_attr_helpers.py",
            "img_firmware_isinstance.py",
            "img_firmware_min_varargs.py",
            "img_builtin_str.py",
            "img_print_basic.py",
            "img_print_sep_end.py",
            "img_print_star_kw.py",
            "img_varargs_kwonly2.py",
        ):
            text = (root / name).read_text(encoding="utf-8")
            image = image_from_source.build_image_from_source_text(text, name)
            self.assertGreater(len(image.program_slots), 0)
            self.assertGreaterEqual(
                len(image.code_handles),
                len(image_from_source.ROM_FIRMWARE_BUILTINS),
            )


class RomFirmwareSemanticsTest(unittest.TestCase):
    """Host-level semantics for wave-3 firmware bodies."""

    def test_print_body_kwargs(self) -> None:
        """ROM print body joins with sep/end (host stand-in for _bi_print)."""
        import io

        path = image_from_source.FIRMWARE_BUILTINS_DIR / "print.py"
        buf = io.StringIO()

        def _bi_print(x):
            if x is None:
                buf.write("None")
            elif x is True:
                buf.write("True")
            elif x is False:
                buf.write("False")
            else:
                buf.write(str(x))

        ns: dict[str, object] = {"_bi_print": _bi_print, "len": len}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        print_fn = ns["print"]
        print_fn(1, 2, sep=",", end=";")
        print_fn(3, end="")
        print_fn()
        self.assertEqual(buf.getvalue(), "1,2;3\n")
        buf.seek(0)
        buf.truncate(0)
        print_fn(* (10, 20, 30), sep="-")
        self.assertEqual(buf.getvalue(), "10-20-30\n")

    def test_numeric_helpers(self) -> None:
        divmod_ = _load_firmware("divmod")
        pow_ = _load_firmware("pow")
        round_ = _load_firmware("round")
        min_ = _load_firmware("min")
        self.assertEqual(divmod_(17, 5), (3, 2))
        self.assertEqual(pow_(2, 10), 1024)
        self.assertEqual(pow_(2, 10, 100), 24)
        self.assertEqual(round_(5), 5)
        self.assertIs(type(round_(5)), int)
        self.assertEqual(min_(9, 4), 4)
        self.assertEqual(min_([3, 1, 2]), 1)
        self.assertEqual(min_(8, 3, 5), 3)
        self.assertEqual(min_(7, 9, 2, 8), 2)
        self.assertEqual(min_(1, 1, 4), 1)
        with self.assertRaises(TypeError):
            min_()

    def test_string_helpers(self) -> None:
        bin_ = _load_firmware("bin")
        hex_ = _load_firmware("hex")
        oct_ = _load_firmware("oct")
        self.assertEqual(bin_(5), "0b101")
        self.assertEqual(bin_(-2), "-0b10")
        self.assertEqual(hex_(255), "0xff")
        self.assertEqual(oct_(8), "0o10")

    def test_containers(self) -> None:
        list_ = _load_firmware("list")
        dict_ = _load_firmware("dict")
        tuple_ = _load_firmware("tuple")
        reversed_ = _load_firmware("reversed")
        filter_ = _load_firmware("filter")
        sorted_ = _load_firmware("sorted")
        self.assertEqual(list_((1, 2, 3)), [1, 2, 3])
        self.assertEqual(dict_([(1, 10), (2, 20)])[2], 20)
        self.assertEqual(tuple_([1, 2]), (1, 2))
        self.assertEqual(reversed_([1, 2, 3]), [3, 2, 1])
        self.assertEqual(filter_(None, [0, 1, 2]), [1, 2])
        self.assertEqual(sorted_([3, 1, 2]), [1, 2, 3])
        self.assertEqual(sorted_([3, 1, 2], reverse=True), [3, 2, 1])

    def test_sum_start_kw(self) -> None:
        sum_ = _load_firmware("sum")
        self.assertEqual(sum_([1, 2, 3], start=10), 16)

    def test_pow_negative_exp_with_mod_raises(self) -> None:
        """Only a non-invertible base raises; pow(2, -1, 5) is 3 as in CPython."""
        pow_ = _load_firmware("pow")
        self.assertEqual(pow_(2, -1, 5), 3)
        with self.assertRaises(ValueError):
            pow_(2, -1, 4)
        with self.assertRaises(ValueError):
            pow_(2, 3, 0)

    def test_pow_mod_matches_cpython(self) -> None:
        """Modular pow: sign of mod, negative exponents, overflow-safe mulmod."""
        import random

        pow_ = _load_firmware("pow")
        cases = [
            (2, 3, -5),
            (-2, 3, 5),
            (3, -1, 7),
            (3, -2, 7),
            (7, 0, 1),
            (0, 0, 3),
            (5, 2, 1),
            (123456789, 987654321, 2**62 - 57),
            (2**62 - 1, 2**61, 2**62 - 1),
            (-(2**62) + 1, 12345, 2**62 - 57),
            (2**62 - 3, -1, 2**62 - 57),
            (3, 10**18, -(2**62 - 57)),
        ]
        rng = random.Random(7)
        for _ in range(300):
            m = rng.choice(
                [rng.randint(1, 2**31), rng.randint(2**31, 2**62), -rng.randint(1, 2**62)]
            )
            b = rng.randint(-(2**62), 2**62)
            e = rng.randint(0, 2**40)
            cases.append((b, e, m))
        for b, e, m in cases:
            with self.subTest(b=b, e=e, m=m):
                self.assertEqual(pow_(b, e, m), pow(b, e, m))
        for _ in range(100):
            m = rng.randint(2, 2**62)
            b = rng.randint(-(2**62), 2**62)
            e = -rng.randint(1, 1000)
            try:
                expect = pow(b, e, m)
            except ValueError:
                with self.assertRaises(ValueError):
                    pow_(b, e, m)
            else:
                self.assertEqual(pow_(b, e, m), expect)

    def test_round_half_even_and_ndigits_match_cpython(self) -> None:
        """round(): ties to even, int result for 1-arg, bit-exact round(x, n)."""
        import random

        round_ = _load_firmware("round")
        self.assertEqual(round_(0.5), 0)
        self.assertEqual(round_(1.5), 2)
        self.assertEqual(round_(2.5), 2)
        self.assertEqual(round_(-0.5), 0)
        self.assertEqual(round_(-2.5), -2)
        self.assertIs(type(round_(2.5)), int)
        self.assertEqual(round_(True), 1)
        self.assertIs(type(round_(True)), int)
        self.assertEqual(round_(7, 2), 7)
        self.assertEqual(round_(15, -1), 20)
        self.assertEqual(round_(25, -1), 20)
        self.assertEqual(round_(-35, -1), -40)
        self.assertEqual(round_(123456, -3), 123000)
        self.assertEqual(round_(5, -30), 0)
        self.assertTrue(_same_float(round_(2.675, 2), round(2.675, 2)))
        self.assertTrue(_same_float(round_(0.125, 2), round(0.125, 2)))
        self.assertTrue(_same_float(round_(-0.0, 1), round(-0.0, 1)))
        self.assertTrue(_same_float(round_(1e300, -290), round(1e300, -290)))
        nan = float("nan")
        inf = float("inf")
        self.assertTrue(_same_float(round_(nan, 1), nan))
        self.assertTrue(_same_float(round_(inf, 1), inf))
        with self.assertRaises(ValueError):
            round_(nan)
        with self.assertRaises(ValueError):
            round_(inf)
        with self.assertRaises(ValueError):
            round_(1.7976931348623157e308, -308)
        rng = random.Random(11)
        for _ in range(3000):
            x = rng.choice(
                [
                    rng.uniform(-1e6, 1e6),
                    rng.randint(-10**7, 10**7) / 1000.0,
                    rng.randint(-10**5, 10**5) + 0.5,
                    rng.uniform(-1, 1) * 10.0 ** rng.randint(-20, 20),
                    rng.randint(0, 2**53) * 1.0,
                ]
            )
            n = rng.randint(-22, 22)
            with self.subTest(x=x, n=n):
                self.assertTrue(_same_float(round_(x, n), round(x, n)))
                if abs(x) < 2**62:
                    self.assertEqual(round_(x), round(x))
            k = rng.randint(-(2**62), 2**62)
            m = rng.randint(-18, 3)
            self.assertEqual(round_(k, m), round(k, m))

    def test_float_from_str_matches_cpython(self) -> None:
        """float(str) is correctly rounded for <= 18 significant digits."""
        import random

        float_ = _load_firmware("float")
        self.assertTrue(_same_float(float_(3), 3.0))
        self.assertTrue(_same_float(float_(True), 1.0))
        self.assertTrue(_same_float(float_(), 0.0))
        self.assertTrue(_same_float(float_(" -1_000.5e-1\n"), -100.05))
        for s in [
            "0",
            "-0.0",
            ".5",
            "1.",
            "2.675",
            "1e22",
            "1e23",
            "9007199254740993",
            "123456789012345678",
            "1.7976931348623157e308",
            "1.7976931348623158e308",
            "1.7976931348623159e308",
            "2.2250738585072011e-308",
            "4.9e-324",
            "2.4703282292062327e-324",
            "2.4703282292062328e-324",
            "1e-400",
            "1e400",
            "17976931348623157e292",
            "1000000000000000000e-331",
            "inf",
            "-Infinity",
            "nan",
            "  +1.5E+3  ",
            "1_0e1_0",
        ]:
            with self.subTest(s=s):
                self.assertTrue(_same_float(float_(s), float(s)), (s, float_(s)))
        for s in [
            "",
            " ",
            "-",
            ".",
            "1..2",
            "1e",
            "1e+",
            "e5",
            "1x",
            "--1",
            "1 2",
            "- 1",
            "1__0",
            "_1",
            "1_",
            "1_.5",
            "1e_5",
            "inf_",
            "in f",
            "nanx",
        ]:
            with self.subTest(s=s):
                with self.assertRaises(ValueError):
                    float_(s)
        with self.assertRaises(TypeError):
            float_(None)
        rng = random.Random(5)
        for _ in range(3000):
            digits = rng.randint(0, 10 ** rng.randint(1, 18))
            e = rng.randint(-345, 320)
            s = f"{digits}e{e}"
            if rng.random() < 0.3:
                s = f"{rng.uniform(-1000, 1000):.{rng.randint(0, 15)}f}"
            with self.subTest(s=s):
                self.assertTrue(_same_float(float_(s), float(s)), (s, float_(s)))

    def test_range_zero_step_raises_valueerror(self) -> None:
        range_ = _load_firmware("range")
        with self.assertRaises(ValueError):
            range_(0, 1, 0)

    def test_next_exhausted_raises_stopiteration(self) -> None:
        next_ = _load_firmware("next")
        with self.assertRaises(StopIteration):
            next_([])


WAVE3_PROGRAM_GOLDENS = {
    "img_firmware_wave3a.py": 432,
    "img_firmware_wave3_strings.py": 111,
    "img_firmware_wave3_pow.py": 169,
    "img_firmware_wave3_containers.py": 349,
    "img_firmware_sorted_kw.py": 460,
    "img_firmware_filter_pred.py": 9,
    "img_firmware_tuple_empty.py": 101,
    "img_firmware_min_varargs.py": 10,
}


class RomFirmwareProgramGoldenTest(unittest.TestCase):
    """Run wave-3 image programs on the host against firmware bodies."""

    def test_wave3_program_goldens(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for fname, expect in WAVE3_PROGRAM_GOLDENS.items():
            with self.subTest(program=fname):
                text = (root / fname).read_text(encoding="utf-8")
                g = {"__name__": "__pycore_host__", "range": range}
                g.update(image_from_source.load_rom_firmware_callables())
                exec(compile(text, fname, "exec"), g)
                self.assertEqual(g["managed_entry"](), expect)

    def test_host_entry_result_matches_wave3_goldens(self) -> None:
        """Makefile host-golden path must inject ROM firmware (not CPython)."""
        from run_image_test import host_entry_result

        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for fname, expect in WAVE3_PROGRAM_GOLDENS.items():
            with self.subTest(program=fname):
                self.assertEqual(
                    host_entry_result(root / fname, "managed_entry"),
                    expect,
                )


if __name__ == "__main__":
    unittest.main()
