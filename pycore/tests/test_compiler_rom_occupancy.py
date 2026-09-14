"""T0 (c): measure current boot-image ROM slot occupancy and heap use.

compiler_design.md §7 estimated ~2 000 ROM slots for boot + firmware. This
test records the live numbers so later compiler seeding has a baseline, and
fails if occupancy silently jumps toward the 8 192-slot ROM ceiling.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("ROM occupancy tests require Python 3.14")

from encoding import HEAP_BASE, HEAP_LIMIT
import image_from_source

# ROM is PYCORE_IMEM_BLOCK_COUNT * 4096 / 8 = 8192 slots.
ROM_SLOT_CEILING = 8192
# Heap is PYCORE_HEAP_BASE .. PYCORE_HEAP_LIMIT (~960 KB).
HEAP_BUDGET = HEAP_LIMIT - HEAP_BASE

# Measured 2026-09-14 on main (T0). Bump only with a comment if firmware
# growth is intentional; do not let a silent 2× jump land.
FIRMWARE_SLOTS_GOLDEN = 2365
SMOKE_SLOTS_GOLDEN = 2384
# Inclusive upper bound: firmware growth of a few hundred slots is fine;
# overflowing ROM is not.
FIRMWARE_SLOTS_MAX = 4000


def _firmware_only_slots() -> int:
    serializer = image_from_source._ImageSerializer()
    image_from_source.build_builtins_dict(serializer)
    return len(serializer.program_slots)


def _smoke_image() -> image_from_source.ImageBuildResult:
    src_path = (
        pathlib.Path(__file__).resolve().parents[1] / "programs" / "img_smoke.py"
    )
    return image_from_source.build_image_from_source_text(
        src_path.read_text(encoding="utf-8"), str(src_path)
    )


class BootOccupancyTest(unittest.TestCase):
    def test_firmware_fits_rom_with_headroom(self) -> None:
        slots = _firmware_only_slots()
        self.assertGreater(slots, 0)
        self.assertLessEqual(slots, FIRMWARE_SLOTS_MAX)
        self.assertLess(slots, ROM_SLOT_CEILING)
        # Pin the measured baseline so a surprise doubling fails CI.
        self.assertLessEqual(slots, FIRMWARE_SLOTS_GOLDEN + 256)
        self.assertGreaterEqual(slots, FIRMWARE_SLOTS_GOLDEN - 256)

    def test_smoke_image_slots_and_heap(self) -> None:
        image = _smoke_image()
        slots = len(image.program_slots)
        heap_bytes = image.heap_init_ptr - HEAP_BASE
        self.assertLess(slots, ROM_SLOT_CEILING)
        self.assertLess(heap_bytes, HEAP_BUDGET)
        self.assertLessEqual(slots, SMOKE_SLOTS_GOLDEN + 256)
        self.assertGreaterEqual(slots, SMOKE_SLOTS_GOLDEN - 256)
        # Static image of a tiny program should stay well under 100 KB.
        self.assertLess(heap_bytes, 100_000)

    def test_user_program_is_a_small_fraction(self) -> None:
        firmware = _firmware_only_slots()
        smoke = len(_smoke_image().program_slots)
        self.assertGreaterEqual(smoke, firmware)
        self.assertLess(smoke - firmware, 256)


if __name__ == "__main__":
    unittest.main()
