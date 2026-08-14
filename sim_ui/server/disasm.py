"""Build a PC → mnemonic map from program.hex (image imem)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .decode import opcode_name


def disasm_program_hex(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    pc = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("@"):
            continue
        word = int(line, 16)
        op = word & 0xFF
        arg = (word >> 8) & 0xFFFFFFFF
        name = opcode_name(op)
        if name == "CACHE" or op == 0:
            # Still include CACHE slots so PC indices stay 1:1 with imem.
            rows.append(
                {
                    "pc": pc,
                    "opcode": name,
                    "opcode_id": op,
                    "oparg": arg,
                    "text": f"{pc:4d}: CACHE",
                    "is_cache": True,
                }
            )
        else:
            rows.append(
                {
                    "pc": pc,
                    "opcode": name,
                    "opcode_id": op,
                    "oparg": arg,
                    "text": f"{pc:4d}: {name} {arg}",
                    "is_cache": False,
                }
            )
        pc += 1
    return rows
