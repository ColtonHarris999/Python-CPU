"""Parse CPython 3.14 exception tables for PyCore image generation."""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from typing import Protocol


class _HasExceptionTable(Protocol):
    co_exceptiontable: bytes


@dataclass(frozen=True)
class ExceptionTableEntry:
    """One CPython exception-table entry, expressed in byte offsets."""

    start: int
    end: int
    target: int
    depth: int
    lasti: bool


@dataclass(frozen=True)
class SlotExceptionTableEntry:
    """One exception-table entry converted to PyCore imem slots."""

    start_slot: int
    end_slot: int
    target_slot: int
    depth: int
    lasti: bool


def _parse_varint(iterator: Iterator[int]) -> int:
    byte = next(iterator)
    value = byte & 0x3F
    while byte & 0x40:
        byte = next(iterator)
        value = (value << 6) | (byte & 0x3F)
    return value


def _exception_table_bytes(
    source: bytes | bytearray | memoryview | _HasExceptionTable,
) -> bytes:
    if isinstance(source, (bytes, bytearray, memoryview)):
        return bytes(source)
    return bytes(source.co_exceptiontable)


def parse_exception_table(
    source: bytes | bytearray | memoryview | _HasExceptionTable,
) -> list[ExceptionTableEntry]:
    """Mirror ``dis._parse_exception_table`` without importing private APIs."""

    iterator = iter(_exception_table_bytes(source))
    entries: list[ExceptionTableEntry] = []
    try:
        while True:
            start = _parse_varint(iterator) * 2
            length = _parse_varint(iterator) * 2
            target = _parse_varint(iterator) * 2
            depth_lasti = _parse_varint(iterator)
            entries.append(
                ExceptionTableEntry(
                    start=start,
                    end=start + length,
                    target=target,
                    depth=depth_lasti >> 1,
                    lasti=bool(depth_lasti & 1),
                )
            )
    except StopIteration:
        return entries


def entries_to_slots(
    entries: Iterable[ExceptionTableEntry], code_entry_slot: int
) -> list[SlotExceptionTableEntry]:
    """Convert CPython byte offsets to absolute PyCore imem slot targets."""

    if code_entry_slot < 0:
        raise ValueError("code_entry_slot must be non-negative")

    converted: list[SlotExceptionTableEntry] = []
    for entry in entries:
        if entry.start & 1 or entry.end & 1 or entry.target & 1:
            raise ValueError("exception table byte offsets must be even")
        converted.append(
            SlotExceptionTableEntry(
                start_slot=entry.start >> 1,
                end_slot=entry.end >> 1,
                target_slot=code_entry_slot + (entry.target >> 1),
                depth=entry.depth,
                lasti=entry.lasti,
            )
        )
    return converted


def _encode_varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("exception-table varint must be non-negative")
    # Parse shifts left as continuation bytes arrive, so the first byte is
    # the most-significant 6-bit chunk (CPython 3.14 / PyCPython assemble.py).
    chunks: list[int] = []
    chunks.append(value & 0x3F)
    value >>= 6
    while value:
        chunks.append(value & 0x3F)
        value >>= 6
    chunks.reverse()
    out = bytearray()
    last = len(chunks) - 1
    i = 0
    while i < last:
        out.append(0x40 | chunks[i])
        i += 1
    out.append(chunks[last])
    return bytes(out)


def encode_exception_table(
    entries: Iterable[ExceptionTableEntry],
) -> bytes:
    """Encode entries as CPython 3.14 6-bit exception-table varints (W-3)."""

    out = bytearray()
    for entry in entries:
        if entry.start & 1 or entry.end & 1 or entry.target & 1:
            raise ValueError("exception table byte offsets must be even")
        if entry.end < entry.start:
            raise ValueError("exception table end precedes start")
        start = _encode_varint(entry.start >> 1)
        out.append(start[0] | 0x80)
        out += start[1:]
        out += _encode_varint((entry.end - entry.start) >> 1)
        out += _encode_varint(entry.target >> 1)
        out += _encode_varint((entry.depth << 1) | int(bool(entry.lasti)))
    return bytes(out)


def parse_exception_table_slots(
    source: bytes | bytearray | memoryview | _HasExceptionTable,
    code_entry_slot: int,
) -> list[SlotExceptionTableEntry]:
    """Parse an exception table and apply the host-side slot conversion."""

    return entries_to_slots(parse_exception_table(source), code_entry_slot)
