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
    spec.loader.exec_module(mod)
    return getattr(mod, name)


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
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 28)

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
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 28)
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
        self.assertEqual(round_(5), 5.0)
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
        pow_ = _load_firmware("pow")
        with self.assertRaises(ValueError):
            pow_(2, -1, 5)

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
