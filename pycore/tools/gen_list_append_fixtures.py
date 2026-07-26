#!/usr/bin/env python3.14
"""Generate the LIST_APPEND (Phase A) hand-built test fixtures.

compile() only emits LIST_APPEND inside list comprehensions. These fixtures
remain hand-assembled because they require spare-capacity/full-list layouts
that source compilation cannot express directly; they target the
CONT_LIST_APPEND opcode/stack contract documented in pycore_defs.svh.

  list_append_fast.{hex,dmem.hex}:
    A hand-built image (BOOT_EN=1) whose co_consts[0] is a list literal with
    capacity=4, length=1 (heap_image.alloc_list_with_capacity — BUILD_LIST
    itself can never produce spare capacity).  The program appends two more
    elements (fast path, no trap expected), subscripts both back, adds them,
    and returns the sum.

  list_append_full_fatal.hex:
    A plain BOOT_EN=0 legacy stream: BUILD_LIST 1 (capacity==length==1,
    exactly full) followed by one LIST_APPEND — expected to raise
    PY_TRAP_LIST_GROW (trap code 9).  No DMEM_HEX needed; BUILD_LIST
    allocates the list at runtime.

Regenerate with:
    python3.14 pycore/tools/gen_list_append_fixtures.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from encoding import TAG_INT, format_imem_slot, int_value  # noqa: E402
from heap_image import HeapImageBuilder  # noqa: E402
from image_from_source import write_program_hex, write_text  # noqa: E402

PROGRAMS_DIR = pathlib.Path(__file__).resolve().parent.parent / "programs"

# Opcode numbers (mirrors pycore_defs.svh; see its verification comments).
OP_RESUME = 128
OP_LOAD_CONST = 82
OP_LOAD_SMALL_INT = 94
OP_BUILD_LIST = 46
OP_BINARY_OP = 44
OP_LIST_APPEND = 78
OP_RETURN_VALUE = 35
NBARG_SUBSCR = 26
NBARG_ADD = 0

# pycore_defs.svh boot-record / code-object layout constants.
BOOT_RECORD_ADDR = 0x03E0


def _emit(slots: list[str], opcode: int, arg: int = 0) -> None:
    slots.append(format_imem_slot(opcode, arg))


def gen_list_append_fast() -> None:
    """[7] with hand-set capacity 4; append 8, 9; subscript both; return 17."""
    heap = HeapImageBuilder(base=max(0x0400, BOOT_RECORD_ADDR + 64))

    list_handle = heap.alloc_list_with_capacity(
        [(TAG_INT, int_value(7))], capacity=4
    )
    co_consts = heap.alloc_tuple([list_handle])
    co_names = heap.alloc_tuple([])

    slots: list[str] = []
    _emit(slots, OP_RESUME, 0)
    _emit(slots, OP_LOAD_CONST, 0)          # push list handle    [list]
    _emit(slots, OP_LOAD_SMALL_INT, 8)      # push element         [list, 8]
    _emit(slots, OP_LIST_APPEND, 1)         # append -> len=2      [list]
    _emit(slots, OP_LOAD_SMALL_INT, 9)      # push element         [list, 9]
    _emit(slots, OP_LIST_APPEND, 1)         # append -> len=3      [list]
    _emit(slots, OP_LOAD_CONST, 0)          # push list handle     [list]
    _emit(slots, OP_LOAD_SMALL_INT, 1)      # index 1              [list, 1]
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # subscript          [8]
    _emit(slots, OP_LOAD_CONST, 0)          # push list handle     [8, list]
    _emit(slots, OP_LOAD_SMALL_INT, 2)      # index 2              [8, list, 2]
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # subscript          [8, 9]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)   # 8 + 9                [17]
    _emit(slots, OP_RETURN_VALUE, 0)

    module_code = heap.add_code_object(
        entry_slot=0,
        co_consts=co_consts,
        co_names=co_names,
        stacksize=4,
        nlocals=0,
        argcount=0,
    )
    globals_dict = heap.alloc_dict([], slot_count=4)
    heap.write_boot_record(module_code, globals_dict, addr=BOOT_RECORD_ADDR)

    write_program_hex(PROGRAMS_DIR / "list_append_fast.hex", slots)
    heap.write_hex(PROGRAMS_DIR / "list_append_fast_dmem.hex")
    write_text(PROGRAMS_DIR / "list_append_fast_str.hex", "00\n")
    write_text(
        PROGRAMS_DIR / "list_append_fast.meta",
        f"HEAP_INIT_PTR={heap.end_ptr}\n",
    )


def gen_list_append_full_fatal() -> None:
    """BUILD_LIST 1 (exactly full) then LIST_APPEND -> PY_TRAP_LIST_GROW."""
    slots: list[str] = []
    _emit(slots, OP_LOAD_SMALL_INT, 7)   # push element             [7]
    _emit(slots, OP_BUILD_LIST, 1)       # cap=1, len=1             [list]
    _emit(slots, OP_LOAD_SMALL_INT, 99)  # push element to append   [list, 99]
    _emit(slots, OP_LIST_APPEND, 1)      # full -> PY_TRAP_LIST_GROW

    write_program_hex(PROGRAMS_DIR / "list_append_full_fatal.hex", slots)
    write_text(PROGRAMS_DIR / "list_append_full_fatal_str.hex", "00\n")


def main() -> None:
    gen_list_append_fast()
    gen_list_append_full_fatal()
    print("Wrote list_append_fast.{hex,dmem.hex,str.hex} and "
          "list_append_full_fatal.{hex,str.hex} under", PROGRAMS_DIR)


if __name__ == "__main__":
    main()
