"""Host tests for the code address space (Plan 1 P1).

The RTL and the tooling each carry their own copy of the code-region geometry,
so the first test exists purely to make drift between them fail loudly.
"""

import pathlib
import re
import unittest

import encoding
from image_from_source import build_image_from_source_text

RTL_DEFS = (
    pathlib.Path(__file__).resolve().parents[1] / "rtl" / "pycore_defs.svh"
)


def _rtl_param(name: str) -> int:
    text = RTL_DEFS.read_text(encoding="utf-8")
    m = re.search(
        rf"^localparam\s+(?:int|logic\s*\[31:0\])\s+{name}\s*=\s*"
        r"(?:32'h([0-9A-Fa-f_]+)|32'd([0-9_]+)|([0-9_]+));",
        text,
        re.MULTILINE,
    )
    if m is None:
        raise AssertionError(f"{name} not found in {RTL_DEFS}")
    if m.group(1) is not None:
        return int(m.group(1).replace("_", ""), 16)
    return int((m.group(2) or m.group(3)).replace("_", ""))


class TestCodeRegionConstants(unittest.TestCase):
    def test_slot_base_matches_rtl(self):
        self.assertEqual(
            encoding.CODE_RAM_SLOT_BASE, _rtl_param("PYCORE_CODE_RAM_SLOT_BASE")
        )

    def test_slots_match_rtl(self):
        self.assertEqual(
            encoding.CODE_RAM_SLOTS, _rtl_param("PYCORE_CODE_RAM_SLOTS")
        )

    def test_slot_limit_is_consistent(self):
        # The RTL defines the limit as base + slots (an expression, not a
        # literal), so checking the two inputs is what pins it.
        self.assertEqual(
            encoding.CODE_RAM_SLOT_LIMIT,
            encoding.CODE_RAM_SLOT_BASE + encoding.CODE_RAM_SLOTS,
        )
        rtl_text = RTL_DEFS.read_text(encoding="utf-8")
        self.assertIn(
            "PYCORE_CODE_RAM_SLOT_LIMIT =\n"
            "    PYCORE_CODE_RAM_SLOT_BASE + PYCORE_CODE_RAM_SLOTS;",
            rtl_text,
        )

    def test_byte_base_is_slot_base_times_eight(self):
        self.assertEqual(
            encoding.CODE_RAM_BYTE_BASE, encoding.CODE_RAM_SLOT_BASE * 8
        )

    def test_ram_base_equals_rom_slot_count(self):
        # The regions must abut: code RAM starts exactly where the ROM's slots
        # end, otherwise a PC in the gap would fault.
        rom_bytes = _rtl_param("PYCORE_IMEM_BLOCK_COUNT") * (
            1 << _rtl_param("PYCORE_BLOCK_SHIFT")
        )
        self.assertEqual(encoding.CODE_RAM_SLOT_BASE, rom_bytes // 8)


SRC = '''
def helper(x):
    return x + 1


def managed_entry():
    return helper(1)


managed_entry()
'''


class TestSlotBaseOffsets(unittest.TestCase):
    def build(self, slot_base):
        return build_image_from_source_text(
            SRC, "<test>", slot_base=slot_base
        )

    def test_rom_build_starts_at_zero(self):
        img = self.build(0)
        self.assertEqual(min(img.entry_slots.values()), 0)

    def test_code_ram_build_is_offset(self):
        base = encoding.CODE_RAM_SLOT_BASE
        img = self.build(base)
        self.assertEqual(min(img.entry_slots.values()), base)
        self.assertTrue(all(v >= base for v in img.entry_slots.values()))

    def test_offset_is_uniform_and_layout_identical(self):
        # Relocating the image must shift every entry slot by exactly the base
        # and change nothing else about the emitted code.
        base = encoding.CODE_RAM_SLOT_BASE
        rom = self.build(0)
        ram = self.build(base)
        self.assertEqual(rom.program_slots, ram.program_slots)
        self.assertEqual(len(rom.entry_slots), len(ram.entry_slots))
        rom_sorted = sorted(rom.entry_slots.values())
        ram_sorted = sorted(ram.entry_slots.values())
        self.assertEqual([v + base for v in rom_sorted], ram_sorted)

    def test_code_ram_build_fits_in_the_region(self):
        base = encoding.CODE_RAM_SLOT_BASE
        img = self.build(base)
        self.assertLess(
            base + len(img.program_slots), encoding.CODE_RAM_SLOT_LIMIT
        )


if __name__ == "__main__":
    unittest.main()
