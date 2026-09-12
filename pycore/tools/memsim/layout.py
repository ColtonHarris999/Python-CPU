"""Build a real PyCore boot image and expose the dmem address layout."""
from __future__ import annotations

import pathlib
import sys
import types
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))

import image_from_source as ifs           # noqa: E402
from heap_image import dict_key_hash      # noqa: E402

# ---- address math mirrored from pycore_defs.svh -------------------------
def tuple_val_addr(base: int, idx: int) -> int:
    return base + (idx << 5)


def tuple_tag_addr(base: int, idx: int) -> int:
    return base + (idx << 5) + 16


def code_field_val_addr(code_addr: int, field_idx: int) -> int:
    return tuple_val_addr(code_addr, field_idx)


def dict_kval_addr(tbl: int, i: int) -> int:
    return tbl + (i << 6)


def dict_ktag_addr(tbl: int, i: int) -> int:
    return tbl + 16 + (i << 6)


def dict_vval_addr(tbl: int, i: int) -> int:
    return tbl + 32 + (i << 6)


def dict_vtag_addr(tbl: int, i: int) -> int:
    return tbl + 48 + (i << 6)


def dict_table_ptr_addr(obj: int) -> int:
    return obj + 32


F_ENTRY_SLOT, F_CONSTS, F_NAMES, F_META, F_DEFAULTS, F_VARNAMES, \
    F_KWDEFAULTS, F_EXCTABLE = range(8)


@dataclass
class CodeLayout:
    code_addr: int
    entry_slot: int
    consts_base: int
    names_base: int
    consts_len: int
    names_len: int


@dataclass
class ImageLayout:
    result: object
    words: dict[int, int]
    code_layout: dict[int, CodeLayout] = field(default_factory=dict)
    globals_obj: int = 0
    globals_table: int = 0
    globals_slots: int = 0
    builtins_obj: int = 0
    builtins_table: int = 0
    builtins_slots: int = 0
    name_key: dict[str, tuple[int, int]] = field(default_factory=dict)

    def dict_probe(self, tbl: int, slots: int, ktag: int, kval: int) -> list[int]:
        """Return the linear-probe slot sequence up to and including the hit."""
        if slots == 0:
            return []
        mask = slots - 1
        idx = dict_key_hash(ktag, kval) & mask
        seq = []
        for _ in range(slots):
            seq.append(idx)
            slot_ktag_word = self.words.get(dict_ktag_addr(tbl, idx), 0)
            slot_kval = self.words.get(dict_kval_addr(tbl, idx), 0)
            if slot_ktag_word == 0:
                return seq  # empty -> miss
            if (slot_ktag_word & 0xF) == ktag and slot_kval == kval:
                return seq  # hit
            idx = (idx + 1) & mask
        return seq


def set_heap_alignment(align: int | None) -> None:
    """Round every bump allocation up to `align` bytes (None = as-built 16 B).

    The production allocator in heap_image.py / pycore_core.sv only guarantees
    16-byte alignment, so a 64-byte dict slot straddles two cache lines three
    times out of four.  This hook lets the study measure what line-aligning
    the allocator would be worth.
    """
    import heap_image

    if getattr(heap_image.HeapImageBuilder, "_memsim_orig_alloc", None) is None:
        heap_image.HeapImageBuilder._memsim_orig_alloc = \
            heap_image.HeapImageBuilder._alloc

    orig = heap_image.HeapImageBuilder._memsim_orig_alloc
    if align is None:
        heap_image.HeapImageBuilder._alloc = orig
        return

    def aligned(self, nbytes, _orig=orig, _a=align):
        self.ptr = (self.ptr + _a - 1) // _a * _a
        return _orig(self, nbytes)

    heap_image.HeapImageBuilder._alloc = aligned


def build_from_source(source_text: str, filename: str):
    """Fold exactly like the production image flow, then serialize.

    Returns (module_code, ImageLayout); the *same* folded module_code is what
    the tracer executes, so trace identities match image addresses.
    """
    sys.path.insert(0, str(ROOT / "pycore" / "tools"))
    import pycore_cli  # noqa: E402

    module_code, seeds, defaults_map, kwdefaults_map, class_specs = \
        pycore_cli.prepare_module_code(source_text, filename)
    res = ifs.build_image_from_code(
        module_code,
        seeds=seeds,
        defaults_map=defaults_map,
        kwdefaults_map=kwdefaults_map,
        class_specs=class_specs,
    )
    return module_code, _layout_from(res)


def _layout_from(res) -> ImageLayout:
    words = res.heap.words
    lay = ImageLayout(result=res, words=words)

    for co_id, handle in res.code_handles.items():
        addr = handle[1] & 0xFFFFFFFF
        consts_word = words.get(code_field_val_addr(addr, F_CONSTS), 0)
        names_word = words.get(code_field_val_addr(addr, F_NAMES), 0)
        lay.code_layout[co_id] = CodeLayout(
            code_addr=addr,
            entry_slot=res.entry_slots[co_id],
            consts_base=consts_word & 0xFFFFFFFF,
            consts_len=(consts_word >> 64) & 0xFFFFFFFF,
            names_base=names_word & 0xFFFFFFFF,
            names_len=(names_word >> 64) & 0xFFFFFFFF,
        )

    g = res.globals_dict[1] & 0xFFFFFFFF
    lay.globals_obj = g
    lay.globals_slots = (words.get(g, 0) >> 64) & 0xFFFFFFFFFFFFFFFF
    lay.globals_table = words.get(dict_table_ptr_addr(g), 0) & 0xFFFFFFFF

    b = res.builtins_dict[1] & 0xFFFFFFFF
    lay.builtins_obj = b
    lay.builtins_slots = (words.get(b, 0) >> 64) & 0xFFFFFFFFFFFFFFFF
    lay.builtins_table = words.get(dict_table_ptr_addr(b), 0) & 0xFFFFFFFF
    return lay
