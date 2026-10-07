"""Locate the bytecode-dispatch edge inside ``_PyEval_EvalFrameDefault``.

On a default CPython 3.14 build the specializing adaptive interpreter is
on, the experimental JIT is off, and the tail-call interpreter is off.
Every opcode body is compiled into one function, and computed goto
duplicates the dispatch sequence at the end of each handler. Ertl and
Gregg (JILP 2003) define dispatch as fetching the next code unit,
decoding the opcode, and taking the indirect branch that enters the next
handler. That edge is a jump through the opcode table:

    movzwl  (%next_instr), %eax
    ... extract opcode / oparg ...
    jmp     *table(,%opcode,8)

or the same jump split into a load and ``jmp *%reg``. The rest of the
function is inline opcode work, not dispatch. Whole-function attribution
is the RegCPython proxy and it overstates dispatch; Zhang, Xu, and Xu
(Science of Computer Programming, 2022) measured the edge at about 8.5%
of cycles once the basic blocks were separated.

Addresses are the ELF offsets Callgrind records with ``--dump-instr=yes``,
so they match ``objdump -d`` of ``libpython`` without a load bias.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

_INSN = re.compile(
    r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2}\s+)+\s*([a-z][a-z0-9.]*)\s*(.*?)\s*$"
)
_TABLE_JMP = re.compile(r"\*\([^)]*,[^)]*,\s*8\)")
_REG_JMP = re.compile(r"^\*%[a-z0-9]+$")
_TABLE_LOAD = re.compile(r"\([^)]*,[^)]*,\s*8\)")
_SYMBOL = re.compile(
    r":\s+([0-9a-f]+)\s+(\d+)\s+FUNC\s+\S+\s+\S+\s+\S+\s+_PyEval_EvalFrameDefault\b"
)


def _terminator(mnemonic: str) -> bool:
    if mnemonic in {"ret", "retq", "call", "callq", "ud2", "hlt"}:
        return True
    if mnemonic.startswith("j") or mnemonic.startswith("loop"):
        return True
    return False


def _dispatch_jump(insns: list[tuple[int, str, str]], index: int) -> bool:
    _addr, mnemonic, ops = insns[index]
    if mnemonic not in {"jmp", "jmpq"}:
        return False
    if _TABLE_JMP.search(ops):
        return True
    if _REG_JMP.match(ops.replace(" ", "")):
        for prev in range(max(0, index - 3), index):
            if insns[prev][1].startswith("mov") and _TABLE_LOAD.search(insns[prev][2]):
                return True
    return False


def _fetch(mnemonic: str, ops: str) -> bool:
    return mnemonic == "movzwl" and "(" in ops


def dispatch_sites(objdump_text: str) -> tuple[set[int], int]:
    """Return ``(instruction addresses, number of indirect dispatch jumps)``."""
    insns: list[tuple[int, str, str]] = []
    for line in objdump_text.splitlines():
        matched = _INSN.match(line)
        if not matched:
            continue
        addr = int(matched.group(1), 16)
        mnemonic = matched.group(2)
        ops = matched.group(3).split("#", 1)[0].strip()
        insns.append((addr, mnemonic, ops))

    addresses: set[int] = set()
    sites = 0
    for index in range(len(insns)):
        if not _dispatch_jump(insns, index):
            continue
        sites += 1
        start = index
        cursor = index - 1
        while cursor >= 0 and (index - cursor) <= 12:
            if _terminator(insns[cursor][1]):
                break
            start = cursor
            if _fetch(insns[cursor][1], insns[cursor][2]):
                break
            cursor -= 1
        for block_index in range(start, index + 1):
            addresses.add(insns[block_index][0])
    return addresses, sites


def eval_frame_symbol(libpython: Path) -> tuple[int, int]:
    """``(address, size)`` of ``_PyEval_EvalFrameDefault`` from the dynamic table."""
    readelf = subprocess.run(
        ["readelf", "-Ws", str(libpython)],
        check=True,
        capture_output=True,
        text=True,
    )
    for line in readelf.stdout.splitlines():
        matched = _SYMBOL.search(line)
        if matched:
            return int(matched.group(1), 16), int(matched.group(2))
    raise RuntimeError(f"_PyEval_EvalFrameDefault is not exported by {libpython}")


def libpython_dispatch(libpython: Path) -> tuple[set[int], int]:
    address, size = eval_frame_symbol(libpython)
    dump = subprocess.run(
        [
            "objdump",
            "-d",
            f"--start-address={address}",
            f"--stop-address={address + size}",
            str(libpython),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return dispatch_sites(dump.stdout)


def find_libpython() -> Path:
    import sysconfig

    libdir = Path(sysconfig.get_config_var("LIBDIR") or "")
    ldlib = sysconfig.get_config_var("LDLIBRARY") or "libpython3.14.so"
    candidates = [
        libdir / ldlib,
        libdir / f"{ldlib}.1.0",
        libdir / "libpython3.14.so.1.0",
        libdir / "libpython3.14.so",
    ]
    for path in candidates:
        if path.is_file():
            return path
    raise FileNotFoundError(
        "libpython3.14 was not found next to this interpreter; "
        f"looked in {libdir}"
    )
