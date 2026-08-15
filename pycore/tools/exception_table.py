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


def parse_exception_table_slots(
    source: bytes | bytearray | memoryview | _HasExceptionTable,
    code_entry_slot: int,
) -> list[SlotExceptionTableEntry]:
    """Parse an exception table and apply the host-side slot conversion."""

    return entries_to_slots(parse_exception_table(source), code_entry_slot)
