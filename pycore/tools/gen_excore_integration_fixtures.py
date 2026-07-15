#!/usr/bin/env python3.14
"""Phase C system-test fixtures: pycore <-> excore integration.

These are hand-assembled instruction streams (BOOT_EN=1 hand-built images,
same technique as gen_list_append_fixtures.py) exercising the real
CONT_LIST_APPEND -> S_TRAP_MARSHAL -> trap_mailbox -> excore -> S_TRAP_WAIT
round trip end to end, driven by real LIST_APPEND traps rather than a
mocked mailbox (that's Phase B's tb_excore). compile() still cannot emit
LIST_APPEND outside comprehensions (FOR_ITER/GET_ITER remain unimplemented),
so every fixture here is built directly against heap_image.HeapImageBuilder
and the CONT_LIST_APPEND / CALL opcode contracts.

Regenerate with:
    python3.14 pycore/tools/gen_excore_integration_fixtures.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from encoding import TAG_CODE_OBJECT, TAG_INT, format_imem_slot, int_value, pack_code_metadata  # noqa: E402
from heap_image import HeapImageBuilder, Tagged  # noqa: E402
from image_from_source import write_program_hex, write_text  # noqa: E402

PROGRAMS_DIR = pathlib.Path(__file__).resolve().parent.parent / "programs"

OP_RESUME = 128
OP_LOAD_CONST = 82
OP_LOAD_SMALL_INT = 94
OP_BINARY_OP = 44
OP_LIST_APPEND = 78
OP_RETURN_VALUE = 35
OP_PUSH_NULL = 33
OP_CALL = 52
NBARG_SUBSCR = 26
NBARG_ADD = 0

BOOT_RECORD_ADDR = 0x03E0


def _emit(slots: list[str], opcode: int, arg: int = 0) -> None:
    slots.append(format_imem_slot(opcode, arg))


def _write_image(
    name: str,
    heap: HeapImageBuilder,
    slots: list[str],
    module_co_consts: Tagged,
    entry_slot: int = 0,
    stacksize: int = 8,
) -> None:
    co_names = heap.alloc_tuple([])
    module_code = heap.add_code_object(
        entry_slot=entry_slot,
        co_consts=module_co_consts,
        co_names=co_names,
        stacksize=stacksize,
        nlocals=0,
        argcount=0,
    )
    globals_dict = heap.alloc_dict([], slot_count=4)
    heap.write_boot_record(module_code, globals_dict, addr=BOOT_RECORD_ADDR)

    write_program_hex(PROGRAMS_DIR / f"{name}.hex", slots)
    heap.write_hex(PROGRAMS_DIR / f"{name}_dmem.hex")
    write_text(PROGRAMS_DIR / f"{name}_str.hex", "00\n")
    write_text(PROGRAMS_DIR / f"{name}.meta", f"HEAP_INIT_PTR={heap.end_ptr}\n")


def _new_heap() -> HeapImageBuilder:
    return HeapImageBuilder(base=max(0x0400, BOOT_RECORD_ADDR + 64))


def gen_grow_from_zero() -> None:
    """[] (cap 0) -> one LIST_APPEND traps, grows to cap 4; subscript back."""
    heap = _new_heap()
    list_handle = heap.alloc_list([])
    co_consts = heap.alloc_tuple([list_handle])

    slots: list[str] = []
    _emit(slots, OP_RESUME)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 55)
    _emit(slots, OP_LIST_APPEND, 1)        # traps: grow 0 -> 4, append 55
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # -> 55
    _emit(slots, OP_RETURN_VALUE)

    _write_image("grow_from_zero", heap, slots, co_consts)


def gen_fast_path_no_trap() -> None:
    """capacity=4/length=1 list; two appends stay within capacity (no trap)."""
    heap = _new_heap()
    list_handle = heap.alloc_list_with_capacity([(TAG_INT, int_value(7))], capacity=4)
    co_consts = heap.alloc_tuple([list_handle])

    slots: list[str] = []
    _emit(slots, OP_RESUME)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 8)
    _emit(slots, OP_LIST_APPEND, 1)          # fast path: len 1 -> 2
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 9)
    _emit(slots, OP_LIST_APPEND, 1)          # fast path: len 2 -> 3
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 2)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)  # -> 9
    _emit(slots, OP_RETURN_VALUE)

    _write_image("fast_path_no_trap", heap, slots, co_consts)


def gen_grow_oom_fatal() -> None:
    """cap=4/len=4 (full) list -> LIST_APPEND grows to 8; heap positioned so
    the doubled buffer cannot fit -> FATAL(MEM_FAULT) (trap code 7).

    HEAP_INIT_PTR is overridden at the Makefile level (near PYCORE_HEAP_LIMIT)
    -- see the pycore-container-grow-oom-fatal target -- independent of this
    fixture's own (small) static-image address range.
    """
    heap = _new_heap()
    list_handle = heap.alloc_list(
        [(TAG_INT, int_value(i)) for i in (1, 2, 3, 4)]
    )
    co_consts = heap.alloc_tuple([list_handle])

    slots: list[str] = []
    _emit(slots, OP_RESUME)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 99)
    _emit(slots, OP_LIST_APPEND, 1)  # full -> grow 4 -> 8 -> OOM at the
                                      # overridden HEAP_INIT_PTR

    _write_image("grow_oom_fatal", heap, slots, co_consts)


def gen_alias_stability() -> None:
    """Same list object via two direct RF-slot loads and nested inside
    another list; grow via one reference; both other paths see the old
    (7) and new (8) elements. Returns 7+8+7+8 = 30 if aliasing held.
    """
    heap = _new_heap()
    inner = heap.alloc_list_with_capacity([(TAG_INT, int_value(7))], capacity=1)
    outer = heap.alloc_list([inner])
    co_consts = heap.alloc_tuple([inner, outer])

    slots: list[str] = []
    _emit(slots, OP_RESUME)
    _emit(slots, OP_LOAD_CONST, 0)             # [inner]           ref A
    _emit(slots, OP_LOAD_SMALL_INT, 8)
    _emit(slots, OP_LIST_APPEND, 1)            # [inner]  grow 1->2, append 8

    _emit(slots, OP_LOAD_CONST, 0)             # [inner]           ref B (direct)
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [7]
    _emit(slots, OP_LOAD_CONST, 0)             # [7, inner]
    _emit(slots, OP_LOAD_SMALL_INT, 1)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [7, 8]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)      # [15]

    _emit(slots, OP_LOAD_CONST, 1)             # [15, outer]       ref C (nested)
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [15, inner-via-outer]
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [15, 7]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)      # [22]

    _emit(slots, OP_LOAD_CONST, 1)             # [22, outer]
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [22, inner-via-outer]
    _emit(slots, OP_LOAD_SMALL_INT, 1)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [22, 8]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)      # [30]
    _emit(slots, OP_RETURN_VALUE)

    _write_image("alias_stability", heap, slots, co_consts)


def gen_mixed_tags_preserved() -> None:
    """cap=3/len=3 (full) list of [INT 999, SHORT_STR, nested LIST[123]];
    LIST_APPEND grows to cap 6 and appends 555. Verifies the INT and the
    nested LIST handle survive bit-exactly (the nested list stays
    subscriptable), and that the SHORT_STR element between them does not
    corrupt its neighbors. SHORT_STR byte-exact preservation itself is
    covered directly by excore's own tb_excore.sv (Phase B, scenario3).
    Returns 999 + 123 + 555 = 1677.
    """
    heap = _new_heap()
    nested = heap.alloc_list([(TAG_INT, int_value(123))])
    main = heap.alloc_list([
        (TAG_INT, int_value(999)),
        heap_image_short_str("hi"),
        nested,
    ])
    co_consts = heap.alloc_tuple([main])

    slots: list[str] = []
    _emit(slots, OP_RESUME)
    _emit(slots, OP_LOAD_CONST, 0)
    _emit(slots, OP_LOAD_SMALL_INT, 555)
    _emit(slots, OP_LIST_APPEND, 1)            # full -> grow 3->6, append 555

    _emit(slots, OP_LOAD_CONST, 0)             # [main]
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [999]
    _emit(slots, OP_LOAD_CONST, 0)             # [999, main]
    _emit(slots, OP_LOAD_SMALL_INT, 2)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [999, nested]
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [999, 123] (nested still subscriptable)
    _emit(slots, OP_BINARY_OP, NBARG_ADD)      # [1122]
    _emit(slots, OP_LOAD_CONST, 0)             # [1122, main]
    _emit(slots, OP_LOAD_SMALL_INT, 3)
    _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)   # [1122, 555]
    _emit(slots, OP_BINARY_OP, NBARG_ADD)      # [1677]
    _emit(slots, OP_RETURN_VALUE)

    _write_image("mixed_tags_preserved", heap, slots, co_consts)


def heap_image_short_str(text: str) -> Tagged:
    from encoding import TAG_SHORT_STR, encode_short_string
    return TAG_SHORT_STR, encode_short_string(text.encode("utf-8"))


def gen_grow_repeated() -> None:
    """cap-0 list, 10 appends of 10,20,...,100 in order.  Growth sequence
    0->4->8->16 fires exactly 3 traps (append #1, #5, #9 are the ones that
    land exactly on a full list -- see the comment inline below).  The
    order-sensitive checksum sum(value[i] * (i+1)) only matches the
    expected 3850 if every element landed at the right index after all
    three grows, which is a much stronger check than a plain sum.
    """
    heap = _new_heap()
    list_handle = heap.alloc_list([])
    co_consts = heap.alloc_tuple([list_handle])

    values = [10 * (i + 1) for i in range(10)]

    slots: list[str] = []
    _emit(slots, OP_RESUME)

    for v in values:
        _emit(slots, OP_LOAD_CONST, 0)
        _emit(slots, OP_LOAD_SMALL_INT, v)
        _emit(slots, OP_LIST_APPEND, 1)

    # acc = 0
    _emit(slots, OP_LOAD_SMALL_INT, 0)
    for i in range(10):
        _emit(slots, OP_LOAD_CONST, 0)              # [acc, list]
        _emit(slots, OP_LOAD_SMALL_INT, i)
        _emit(slots, OP_BINARY_OP, NBARG_SUBSCR)    # [acc, value[i]]
        _emit(slots, OP_LOAD_SMALL_INT, i + 1)
        _emit(slots, OP_BINARY_OP, 5)                # MUL (oparg 5) -> value[i]*(i+1)
        _emit(slots, OP_BINARY_OP, NBARG_ADD)        # [acc + value[i]*(i+1)]
    _emit(slots, OP_RETURN_VALUE)

    _write_image("grow_repeated", heap, slots, co_consts, stacksize=8)


def gen_append_across_call() -> None:
    """The trapping LIST_APPEND executes inside a called function (the
    frame stack is non-empty during the marshal/wait handoff).  Callee:
    grows a cap-0 list via LIST_APPEND(77) and returns element[0]; caller
    just calls it with 0 args and returns its result.
    """
    heap = _new_heap()

    # ---- callee code object (serialized first: entry_slot 0) -----------
    callee_list = heap.alloc_list([])
    callee_consts = heap.alloc_tuple([callee_list])

    callee_slots: list[str] = []
    _emit(callee_slots, OP_RESUME)
    _emit(callee_slots, OP_LOAD_CONST, 0)
    _emit(callee_slots, OP_LOAD_SMALL_INT, 77)
    _emit(callee_slots, OP_LIST_APPEND, 1)          # traps inside the callee frame
    _emit(callee_slots, OP_LOAD_CONST, 0)
    _emit(callee_slots, OP_LOAD_SMALL_INT, 0)
    _emit(callee_slots, OP_BINARY_OP, NBARG_SUBSCR)  # -> 77
    _emit(callee_slots, OP_RETURN_VALUE)

    callee_names = heap.alloc_tuple([])
    callee_code = heap.add_code_object(
        entry_slot=0,
        co_consts=callee_consts,
        co_names=callee_names,
        stacksize=4,
        nlocals=0,
        argcount=0,
    )

    # ---- caller (module) code, appended after the callee's slots --------
    caller_slots: list[str] = []
    _emit(caller_slots, OP_RESUME)
    _emit(caller_slots, OP_LOAD_CONST, 0)  # callee code-object handle
    _emit(caller_slots, OP_PUSH_NULL)
    _emit(caller_slots, OP_CALL, 0)
    _emit(caller_slots, OP_RETURN_VALUE)

    module_co_consts = heap.alloc_tuple([callee_code])

    slots = callee_slots + caller_slots
    _write_image(
        "append_across_call", heap, slots, module_co_consts,
        entry_slot=len(callee_slots), stacksize=4,
    )


def main() -> None:
    gen_grow_from_zero()
    gen_fast_path_no_trap()
    gen_grow_oom_fatal()
    gen_alias_stability()
    gen_mixed_tags_preserved()
    gen_grow_repeated()
    gen_append_across_call()
    print("Wrote Phase C integration fixtures under", PROGRAMS_DIR)


if __name__ == "__main__":
    main()
