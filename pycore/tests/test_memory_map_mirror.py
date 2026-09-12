"""encoding.py and pycore_defs.svh must agree on every shared memory-map constant.

The image builder and the RTL each hardcode the heap / exception / frame /
boot-record / code-RAM layout. Drift is a live hazard (HEAP_LIMIT is 0x1B000
in both files by hand). P1 (line alignment) and P5 (string regions) both
touch this mirror — this test is the gate.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from pycore.tools import encoding

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFS_SVH = REPO_ROOT / "pycore" / "rtl" / "pycore_defs.svh"


def _strip_sv_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*?$", "", text, flags=re.M)
    return text


def _sv_int(token: str) -> int:
    token = token.strip().replace("_", "").replace(" ", "")
    if "'b" in token.lower():
        return int(token.split("'b", 1)[-1].split("'B", 1)[-1], 2)
    if "'h" in token.lower():
        return int(token.split("'h", 1)[-1].split("'H", 1)[-1], 16)
    if "'d" in token.lower():
        return int(token.split("'d", 1)[-1].split("'D", 1)[-1], 10)
    if token.lower().startswith("0x"):
        return int(token, 16)
    return int(token, 10)


_SV_LIT = re.compile(
    r"^(?:\d+'[hHdDbB][0-9a-fA-F_]+|\d+'[sS]?[dD][0-9_]+|1'b[01]|0x[0-9a-fA-F]+|\d+)$"
)


def _is_sv_literal(token: str) -> bool:
    return bool(_SV_LIT.match(token.strip().replace(" ", "")))


def parse_simple_localparams(path: Path) -> dict[str, int]:
    """Parse localparam integer assignments, including name-only expressions."""
    text = _strip_sv_comments(path.read_text())
    pattern = re.compile(
        r"localparam\s+(?:bit|int|logic(?:\s*\[[^\]]+\])?)\s+"
        r"([A-Z][A-Z0-9_]*)\s*=\s*([^;]+);",
        re.M,
    )
    raw: list[tuple[str, str]] = [(n, rhs.strip()) for n, rhs in pattern.findall(text)]
    found: dict[str, int] = {}

    def resolve(rhs: str) -> int | None:
        expr = rhs.replace("\n", " ")
        for name, val in sorted(found.items(), key=lambda kv: -len(kv[0])):
            expr = re.sub(rf"\b{name}\b", str(val), expr)
        expr = expr.replace("$unsigned", "")
        compact = expr.replace(" ", "")
        if _is_sv_literal(compact):
            try:
                return _sv_int(compact)
            except ValueError:
                return None
        # Arithmetic over already-resolved names / literals.
        safe = re.sub(r"\d+'h[0-9a-fA-F_]+", lambda m: str(_sv_int(m.group(0))), expr)
        safe = re.sub(r"\d+'d[0-9_]+", lambda m: str(_sv_int(m.group(0))), safe)
        safe = re.sub(r"1'b[01]", lambda m: str(_sv_int(m.group(0))), safe)
        if re.search(r"[A-Za-z$]", safe):
            return None
        try:
            return int(eval(safe, {"__builtins__": {}}, {}))
        except Exception:
            return None

    pending = list(raw)
    for _ in range(len(pending) + 2):
        leftover = []
        for name, rhs in pending:
            val = resolve(rhs)
            if val is None:
                leftover.append((name, rhs))
            else:
                found[name] = val
        if leftover == pending:
            break
        pending = leftover
    return found


# encoding.py name -> pycore_defs.svh name. Only constants that both sides
# own; RTL-only knobs (block counts, data widths) stay out.
SHARED_CONSTANTS = {
    "BOOT_RECORD_ADDR": "PYCORE_BOOT_RECORD_ADDR",
    "BOOT_RECORD_BYTES": "PYCORE_BOOT_RECORD_BYTES",
    "HEAP_BASE": "PYCORE_HEAP_BASE",
    "HEAP_LIMIT": "PYCORE_HEAP_LIMIT",
    "EXC_STACK_BASE": "PYCORE_EXC_STACK_BASE",
    "EXC_STACK_BYTES": "PYCORE_EXC_STACK_BYTES",
    "FRAME_STACK_BASE": "PYCORE_FRAME_STACK_BASE",
    "FRAME_STACK_BYTES": "PYCORE_FRAME_STACK_BYTES",
    "ITER_EXHAUST_TYPE_ADDR": "PYCORE_ITER_EXHAUST_TYPE_ADDR",
    "NATIVE_METHOD_COUNT": "PYCORE_NATIVE_METHOD_COUNT",
    "NATIVE_METHOD_ENTRY_BYTES": "PYCORE_NATIVE_METHOD_ENTRY_BYTES",
    "NATIVE_METHOD_TABLE_BYTES": "PYCORE_NATIVE_METHOD_TABLE_BYTES",
    "NATIVE_METHOD_TABLE_ADDR": "PYCORE_NATIVE_METHOD_TABLE_ADDR",
    "CODE_OBJECT_NFIELDS": "PYCORE_CODE_NFIELDS",
    "CODE_OBJECT_BYTES": "PYCORE_CODE_OBJECT_BYTES",
    "CACHE_EN": "PYCORE_CACHE_EN",
    "LINE_BYTES": "PYCORE_LINE_BYTES",
    "L1I_SIZE_BYTES": "PYCORE_L1I_SIZE_BYTES",
    "L1I_WAYS": "PYCORE_L1I_WAYS",
    "L1D_SIZE_BYTES": "PYCORE_L1D_SIZE_BYTES",
    "L1D_WAYS": "PYCORE_L1D_WAYS",
    "L1D_HIT_CYCLES": "PYCORE_L1D_HIT_CYCLES",
    "L2_SIZE_BYTES": "PYCORE_L2_SIZE_BYTES",
    "L2_WAYS": "PYCORE_L2_WAYS",
    "RAM_BYTES": "PYCORE_RAM_BYTES",
    "RAM_T_FIRST": "PYCORE_RAM_T_FIRST",
    "RAM_T_BEAT": "PYCORE_RAM_T_BEAT",
    "RAM_T_FIRST_CI": "PYCORE_RAM_T_FIRST_CI",
    "CODE_ADDR_BASE": "PYCORE_CODE_ADDR_BASE",
    "L2_HIT_CYCLES": "PYCORE_L2_HIT_CYCLES",
    "DMEM_BYTES": "PYCORE_DMEM_BYTES",
    "CODC_ENTRIES": "PYCORE_CODC_ENTRIES",
    "CODC_WAYS": "PYCORE_CODC_WAYS",
    "GIC_ENTRIES": "PYCORE_GIC_ENTRIES",
    "GIC_WAYS": "PYCORE_GIC_WAYS",
    "FTB_FRAMES": "PYCORE_FTB_FRAMES",
}


class TestMemoryMapMirror(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.svh = parse_simple_localparams(DEFS_SVH)

    def test_svh_parsed_shared_names(self) -> None:
        missing = [rtl for rtl in SHARED_CONSTANTS.values() if rtl not in self.svh]
        self.assertEqual(missing, [], f"unparsed RTL localparams: {missing}")

    def test_encoding_matches_defs(self) -> None:
        mismatches = []
        for py_name, rtl_name in SHARED_CONSTANTS.items():
            py_val = getattr(encoding, py_name)
            rtl_val = self.svh[rtl_name]
            if py_val != rtl_val:
                mismatches.append(f"{py_name}={py_val:#x} vs {rtl_name}={rtl_val:#x}")
        self.assertEqual(mismatches, [], "memory-map drift:\n  " + "\n  ".join(mismatches))

    def test_derived_layout_identities(self) -> None:
        self.assertEqual(encoding.HEAP_BASE, encoding.BOOT_RECORD_ADDR + encoding.BOOT_RECORD_BYTES)
        self.assertEqual(encoding.HEAP_LIMIT, encoding.EXC_STACK_BASE)
        self.assertEqual(
            encoding.ITER_EXHAUST_TYPE_ADDR,
            encoding.EXC_STACK_BASE + encoding.EXC_STACK_BYTES - 32,
        )
        self.assertEqual(
            encoding.NATIVE_METHOD_TABLE_ADDR,
            encoding.ITER_EXHAUST_TYPE_ADDR - encoding.NATIVE_METHOD_TABLE_BYTES,
        )
        self.assertEqual(encoding.CODE_OBJECT_BYTES, encoding.CODE_OBJECT_NFIELDS * 32)
        self.assertLess(encoding.HEAP_LIMIT, encoding.FRAME_STACK_BASE)
        self.assertEqual(
            encoding.EXC_STACK_BASE + encoding.EXC_STACK_BYTES,
            encoding.FRAME_STACK_BASE,
        )
        # P1: the bump allocator start-aligns to LINE_BYTES, so HEAP_BASE
        # itself must already be on a line or the first object would pad.
        self.assertEqual(encoding.HEAP_BASE % encoding.LINE_BYTES, 0)
        self.assertEqual(encoding.align_line(encoding.HEAP_BASE), encoding.HEAP_BASE)
        self.assertEqual(encoding.DMEM_BYTES, 0x20000)
        self.assertEqual(encoding.CODE_ADDR_BASE, 0x01000000)


if __name__ == "__main__":
    unittest.main()
