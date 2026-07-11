"""
End-to-end CPU correctness suite for test_programs/.

For every Python file discovered in test_programs/ this test:
  1. Executes managed_entry() natively under the current Python interpreter to
     obtain the expected return value.
  2. Preprocesses the source file (preprocess.py, requires CPython 3.14) to
     produce hex images.
  3. Runs the pre-built Verilator simulation binary and captures its output.
  4. Decodes the simulation return-entry (tag + 128-bit value) and compares it
     with the expected value obtained in step 1.

Requirements:
  - CPython 3.14 (the same requirement as preprocess.py)
  - Verilator binary at build/pycore_runfile/Vtb_pycore_runfile
    (built by: make pycore-build-runfile)

These constraints are satisfied inside the Docker image used by CI.
"""

from __future__ import annotations

import importlib.util
import struct
import subprocess
import sys
import unittest
from pathlib import Path


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_ROOT          = Path(__file__).resolve().parents[2]   # repo root
TEST_PROGS_DIR = _ROOT / "test_programs"
PREPROCESS     = _ROOT / "pycore" / "tools" / "preprocess.py"
SIM_BIN        = _ROOT / "build" / "pycore_runfile" / "Vtb_pycore_runfile"
PROG_HEX       = _ROOT / "pycore" / "programs" / "run_program.hex"
STRING_HEX     = _ROOT / "pycore" / "programs" / "run_string_mem.hex"
TYPES_FILE     = _ROOT / "pycore" / "programs" / "run_program.types"
CACHE_MAP      = _ROOT / "pycore" / "programs" / "run_cache_map.hex"

# ---------------------------------------------------------------------------
# Tagged-entry constants (mirroring pycore_defs.svh)
# ---------------------------------------------------------------------------
TAG_INT       = 1
TAG_FLOAT     = 2
TAG_BOOL      = 3
TAG_SHORT_STR = 6
TAG_LONG_STR  = 7

SHORT_STR_MAX_BYTES = 15


# ---------------------------------------------------------------------------
# Value conversion helpers
# ---------------------------------------------------------------------------

def _float_bits(v: float) -> int:
    """Return the IEEE-754 double-precision bit pattern of v."""
    return struct.unpack(">Q", struct.pack(">d", v))[0]


def expected_tagged_value(native_val: object) -> tuple[int, int | None]:
    """
    Convert a native Python return value into the (tag, 128-bit value) that
    the CPU should produce.  Returns (tag, None) when only the tag matters
    (e.g. for long strings whose heap address is not predictable).
    """
    if isinstance(native_val, bool):
        return TAG_BOOL, int(native_val)

    if isinstance(native_val, int):
        val64 = native_val & 0xFFFF_FFFF_FFFF_FFFF
        upper = 0xFFFF_FFFF_FFFF_FFFF if native_val < 0 else 0
        return TAG_INT, (upper << 64) | val64

    if isinstance(native_val, float):
        # Float values live in value[63:0]; value[127:64] = 0.
        # When Python prints the 128-bit value as a big-endian hex integer the
        # float bits end up in the low 64 bits of the resulting Python int.
        return TAG_FLOAT, _float_bits(native_val)

    if isinstance(native_val, str):
        b = native_val.encode("utf-8")
        if len(b) <= SHORT_STR_MAX_BYTES:
            # value[127:124] = size (4 bits)
            # value[123:4]   = payload (120 bits), bytes MSB-first
            # value[3:0]     = flags = 0
            val = len(b) << 124
            for i, byte in enumerate(b):
                val |= byte << (116 - i * 8)
            return TAG_SHORT_STR, val
        # Long strings: only the tag is checked; heap address is non-deterministic.
        return TAG_LONG_STR, None

    raise TypeError(f"Unsupported managed_entry return type: {type(native_val)}")


# ---------------------------------------------------------------------------
# Simulation helpers
# ---------------------------------------------------------------------------

def run_native(prog_path: Path) -> object:
    """Import and call managed_entry() natively."""
    spec = importlib.util.spec_from_file_location("_pycore_prog", prog_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    fn = getattr(mod, "managed_entry", None)
    assert callable(fn), f"managed_entry() not found in {prog_path.name}"
    return fn()


def preprocess(prog_path: Path) -> None:
    """Run preprocess.py to compile prog_path → hex images."""
    result = subprocess.run(
        [
            sys.executable, str(PREPROCESS),
            "--source",      str(prog_path),
            "--function",    "managed_entry",
            "--program-hex", str(PROG_HEX),
            "--string-hex",  str(STRING_HEX),
            "--types",       str(TYPES_FILE),
            "--cache-map",   str(CACHE_MAP),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"preprocess.py failed for {prog_path.name}:\n"
            f"{result.stderr}"
        )


def run_simulation() -> tuple[int, int]:
    """
    Execute the pre-built Verilator binary and parse RETURN_TAG / RETURN_VALUE_HEX
    from its stdout.  Returns (tag, value_128bit).
    """
    result = subprocess.run(
        [str(SIM_BIN)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Simulation binary failed (exit {result.returncode}):\n"
            f"{result.stdout}\n{result.stderr}"
        )

    tag: int | None = None
    val: int | None = None
    for line in result.stdout.splitlines():
        if line.startswith("RETURN_TAG="):
            tag = int(line[len("RETURN_TAG="):])
        elif line.startswith("RETURN_VALUE_HEX=0x"):
            val = int(line[len("RETURN_VALUE_HEX=0x"):], 16)

    if tag is None or val is None:
        raise RuntimeError(
            f"Could not parse simulation output:\n{result.stdout}"
        )
    return tag, val


# ---------------------------------------------------------------------------
# Test class — one test method generated per file in test_programs/
# ---------------------------------------------------------------------------

def _make_test_method(prog_path: Path):
    def test_method(self: "TestPrograms") -> None:
        # Step 1: native execution
        native_val = run_native(prog_path)
        exp_tag, exp_val = expected_tagged_value(native_val)

        # Step 2: compile to hex
        preprocess(prog_path)

        # Step 3: simulate
        sim_tag, sim_val = run_simulation()

        # Step 4: compare
        self.assertEqual(
            sim_tag, exp_tag,
            f"{prog_path.name}: tag mismatch — "
            f"expected {exp_tag}, got {sim_tag}  (native={native_val!r})",
        )
        if exp_val is not None:
            self.assertEqual(
                sim_val, exp_val,
                f"{prog_path.name}: value mismatch — "
                f"expected 0x{exp_val:032x}, got 0x{sim_val:032x}  "
                f"(native={native_val!r})",
            )

    test_method.__name__ = f"test_{prog_path.stem}"
    test_method.__doc__  = f"CPU correctness: {prog_path.name}"
    return test_method


class TestPrograms(unittest.TestCase):
    """End-to-end CPU correctness tests for every file in test_programs/."""

    @classmethod
    def setUpClass(cls) -> None:
        if sys.version_info[:2] != (3, 14):
            raise unittest.SkipTest(
                f"test_programs requires CPython 3.14 (preprocess.py constraint); "
                f"running {sys.version_info.major}.{sys.version_info.minor}"
            )
        if not SIM_BIN.exists():
            raise unittest.SkipTest(
                f"Verilator runfile binary not found at:\n  {SIM_BIN}\n"
                "Build it with:  make pycore-build-runfile"
            )


# Dynamically attach one test method per program file.
for _path in sorted(TEST_PROGS_DIR.glob("*.py")):
    _method = _make_test_method(_path)
    setattr(TestPrograms, _method.__name__, _method)


if __name__ == "__main__":
    unittest.main(verbosity=2)
