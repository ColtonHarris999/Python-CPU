#!/usr/bin/env python3.14
"""Generate LIST_EXTEND (single-core) hand-built test fixtures.

Non-empty LIST_EXTEND always raises PY_TRAP_LIST_EXTEND (even with spare
capacity); empty source remains a no-op on pycore. Functional spare-capacity
extend is covered by the two-core extend_fast_no_trap fixture.

  list_extend_fast.* / list_extend_fast_tuple.*:
    Spare-capacity destinations; without excore → trap code 10.

  list_extend_empty.*:
    Destination [42] with spare capacity; extend from []. No-op pop;
    return the original element (42).

  list_extend_full_fatal.hex:
    BOOT_EN=0 stream: BUILD_LIST 1 (full) then LIST_EXTEND from a
    one-element list → PY_TRAP_LIST_EXTEND (code 10). No excore.

  list_extend_type_fatal.hex:
    BOOT_EN=0 stream: BUILD_LIST 0 then LIST_EXTEND from an INT →
    PY_TRAP_TYPE (code 1).

Regenerate with:
    python3.14 pycore/tools/gen_list_extend_fixtures.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from encoding import (  # noqa: E402
    BOOT_RECORD_ADDR,
    HEAP_BASE,
    TAG_INT,
    format_imem_slot,
    int_value,
)
from heap_image import HeapImageBuilder  # noqa: E402
from image_from_source import write_program_hex, write_text  # noqa: E402

PROGRAMS_DIR = pathlib.Path(__file__).resolve().parent.parent / "programs"

OP_RESUME = 128
OP_LOAD_CONST = 82
OP_LOAD_SMALL_INT = 94
OP_BUILD_LIST = 46
OP_BINARY_OP = 44
OP_LIST_EXTEND = 79
OP_RETURN_VALUE = 35
NBARG_SUBSCR = 26
NBARG_ADD = 0


def _emit(slots: list[str], opcode: int, arg: int = 0) -> None:
    slots.append(format_imem_slot(opcode, arg))


def _write_boot_image(
    name: str,
    heap: HeapImageBuilder,
    slots: list[str],
    co_consts,
    stacksize: int = 4,
) -> None:
    co_names = heap.alloc_tuple([])
    co_varnames = heap.alloc_tuple([])
    module_code = heap.add_code_object(
        entry_slot=0,
        co_consts=co_consts,
        co_names=co_names,
        co_varnames=co_varnames,
        stacksize=stacksize,
        nlocals=0,
        argcount=0,
    )
    globals_dict = heap.alloc_dict([], slot_count=4)
    builtins_dict = heap.alloc_dict([], slot_count=4)
    heap.write_boot_record(
        module_code, globals_dict, builtins_dict, addr=BOOT_RECORD_ADDR
    )
    write_program_hex(PROGRAMS_DIR / f"{name}.hex", slots)
    heap.write_hex(PROGRAMS_DIR / f"{name}_dmem.hex")
    write_text(PROGRAMS_DIR / f"{name}_str.hex", "00\n")
    write_text(PROGRAMS_DIR / f"{name}.meta", f"HEAP_INIT_PTR={heap.end_ptr}\n")


def gen_list_extend_fast() -> None:
    """cap=8/len=2 list; extend [9,10]; return new[2]+new[3] = 19."""
    heap = HeapImageBuilder(base=HEAP_BASE)
    dst = heap.alloc_list_with_capacity(
        [(TAG_INT, int_value(7)), (TAG_INT, int_value(8))], capacity=8
    )
    src = heap.alloc_list([(TAG_INT, int_value(9)), (TAG_INT, int_value(10))])
    co_consts = heap.alloc_tuple([dst, src])

    slots: list[str] = []
    _emit(slots, OP_RESUME, 0)
    _emit(slots, OP_LOAD_CONST, 0)           # [dst]
    _emit(slots, OP_LOAD_CONST, 1)           # [dst, src]
    _emit(slots, OP_LIST_EXTEND, 1)          # non-empty → trap 10 (no excore)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 2)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # [9]
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 3)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # [9, 10]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)    # [19]
    _emit(slots, OP_RETURN_VALUE, 0)

    _write_boot_image("list_extend_fast", heap, slots, co_consts)


def gen_list_extend_fast_tuple() -> None:
    """cap=8/len=2 list; extend tuple (11, 12); return 11+12 = 23."""
    heap = HeapImageBuilder(base=HEAP_BASE)
    dst = heap.alloc_list_with_capacity(
        [(TAG_INT, int_value(7)), (TAG_INT, int_value(8))], capacity=8
    )
    src = heap.alloc_tuple([(TAG_INT, int_value(11)), (TAG_INT, int_value(12))])
    co_consts = heap.alloc_tuple([dst, src])

    slots: list[str] = []
    _emit(slots, OP_RESUME, 0)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_CONST, 1)
    _emit(slots, OP_LIST_EXTEND, 1)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 2)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 3)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)
    _emit(slots, OP_BINARY_OP, NBARG_ADD)
    _emit(slots, OP_RETURN_VALUE, 0)

    _write_boot_image("list_extend_fast_tuple", heap, slots, co_consts)


def gen_list_extend_empty() -> None:
    """Extend with empty list — no-op pop; return original element 42."""
    heap = HeapImageBuilder(base=HEAP_BASE)
    dst = heap.alloc_list_with_capacity([(TAG_INT, int_value(42))], capacity=4)
    src = heap.alloc_list([])
    co_consts = heap.alloc_tuple([dst, src])

    slots: list[str] = []
    _emit(slots, OP_RESUME, 0)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_CONST, 1)
    _emit(slots, OP_LIST_EXTEND, 1)          # empty → pop only
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # [42]
    _emit(slots, OP_RETURN_VALUE, 0)

    _write_boot_image("list_extend_empty", heap, slots, co_consts)


def gen_list_extend_full_fatal() -> None:
    """BUILD_LIST 1 (full) + LIST_EXTEND from [99] → PY_TRAP_LIST_EXTEND."""
    slots: list[str] = []
    _emit(slots, OP_LOAD_SMALL_INT, 7)
    _emit(slots, OP_BUILD_LIST, 1)           # dst cap=len=1
    _emit(slots, OP_LOAD_SMALL_INT, 99)
    _emit(slots, OP_BUILD_LIST, 1)           # src
    _emit(slots, OP_LIST_EXTEND, 1)          # 1+1 > 1 → trap 10

    write_program_hex(PROGRAMS_DIR / "list_extend_full_fatal.hex", slots)
    write_text(PROGRAMS_DIR / "list_extend_full_fatal_str.hex", "00\n")


def gen_list_extend_type_fatal() -> None:
    """LIST_EXTEND from an INT → PY_TRAP_TYPE."""
    slots: list[str] = []
    _emit(slots, OP_BUILD_LIST, 0)           # empty dst
    _emit(slots, OP_LOAD_SMALL_INT, 5)       # INT iterable (unsupported)
    _emit(slots, OP_LIST_EXTEND, 1)

    write_program_hex(PROGRAMS_DIR / "list_extend_type_fatal.hex", slots)
    write_text(PROGRAMS_DIR / "list_extend_type_fatal_str.hex", "00\n")


def main() -> None:
    gen_list_extend_fast()
    gen_list_extend_fast_tuple()
    gen_list_extend_empty()
    gen_list_extend_full_fatal()
    gen_list_extend_type_fatal()
    print("Wrote list_extend_* fixtures under", PROGRAMS_DIR)


if __name__ == "__main__":
    main()
