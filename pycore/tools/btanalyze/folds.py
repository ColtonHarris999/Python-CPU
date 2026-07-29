"""Instruction-folding candidate detection (picoJava-style, Python-derived).

Each instruction is classified by its dataflow shape (SRC/UNY/RDX/SNK/BRC/BAR).
Within a basic block, the matcher does *maximal munch*: at each instruction
boundary it tries the catalog's category sequences longest-first, so the biggest
legal fold wins (F1 over F2/F6). A run is a candidate only if it is barrier-free,
self-contained on the operand stack, lands on instruction boundaries, and (for
``requires_support`` groups) every op in it is executable today.

A compiler-pre-fused dual load (``LOAD_FAST_BORROW_LOAD_FAST_BORROW``) counts as
two SRC slots from a single instruction, so it satisfies an ``SRC SRC`` prefix
without being split.
"""

from __future__ import annotations

from dataclasses import dataclass

from .cfg import CFG, Instr
from .report import FoldCandidate
from .targets import TargetModel


# Per-category (pops, pushes) arity used to simulate operand-stack depth.
_ARITY = {
    "SRC": (0, None),  # pushes filled in per-instruction (1 or 2)
    "UNY": (1, 1),
    "RDX": (2, 1),
    "SNK": (None, 0),  # pops filled in per-instruction (1 or 2)
    "BRC": (1, 0),
}


@dataclass
class _Slot:
    cat: str
    instr: Instr
    first: bool  # first slot contributed by its instruction
    last: bool  # last slot contributed by its instruction


@dataclass
class FoldResult:
    candidates: list[FoldCandidate]
    site_count: int


def _slot_arity(slot: _Slot, target: TargetModel) -> tuple[int, int]:
    """Resolve (pops, pushes) for a slot, expanding SRC/SNK multiplicity."""
    if slot.cat == "SRC":
        return 0, 1  # each SRC *slot* pushes exactly one value
    if slot.cat == "SNK":
        return 1, 0  # each SNK *slot* pops exactly one value
    pops, pushes = _ARITY[slot.cat]
    return pops, pushes


def _effective_fold(target: TargetModel, ins: Instr) -> str:
    return target.classify(ins.opname, ins.arg).fold


def _multiplicity(target: TargetModel, ins: Instr, cat: str) -> int:
    entry = target.opcodes.get(ins.opname, {})
    if cat == "SRC":
        return int(entry.get("pushes", 1))
    if cat == "SNK":
        return int(entry.get("pops", 1))
    return 1


def _build_slots(target: TargetModel, segment: list[Instr]) -> list[_Slot]:
    slots: list[_Slot] = []
    for ins in segment:
        cat = _effective_fold(target, ins)
        count = _multiplicity(target, ins, cat)
        for k in range(count):
            slots.append(
                _Slot(cat=cat, instr=ins, first=(k == 0), last=(k == count - 1))
            )
    return slots


def _split_segments(target: TargetModel, instrs: list[Instr]) -> list[list[Instr]]:
    """Break a block into maximal barrier-free runs."""
    segments: list[list[Instr]] = []
    current: list[Instr] = []
    for ins in instrs:
        if _effective_fold(target, ins) == "BAR":
            if current:
                segments.append(current)
                current = []
            continue
        current.append(ins)
    if current:
        segments.append(current)
    return segments


def _covered_instructions(slots: list[_Slot], start: int, length: int) -> list[Instr]:
    seen: list[Instr] = []
    for k in range(start, start + length):
        ins = slots[k].instr
        if not seen or seen[-1] is not ins:
            seen.append(ins)
    return seen


def _self_contained(slots: list[_Slot], start: int, length: int,
                    target: TargetModel, last_cat: str) -> bool:
    """Criterion 4: barrier-free run that closes its own operand-stack use."""
    depth = 0
    for k in range(start, start + length):
        pops, pushes = _slot_arity(slots[k], target)
        if depth < pops:  # would consume a value produced outside the run
            return False
        depth += pushes - pops
    expected_final = 0 if last_cat in ("SNK", "BRC") else 1
    return depth == expected_final


def _passes_safety(insns: list[Instr], group: dict, target: TargetModel) -> tuple[bool, list[str]]:
    """Criteria 2 and 6; also collect needs_ops (reject/partial members)."""
    # Criterion 2: only the leader may be a jump target.
    for ins in insns[1:]:
        if ins.is_jump_target:
            return False, []

    needs_ops: list[str] = []
    requires_support = bool(group.get("requires_support"))
    for ins in insns:
        info = target.classify(ins.opname, ins.arg)
        if info.support in ("reject", "trap"):
            if requires_support:
                return False, []
            needs_ops.append(ins.opname)
        elif info.support == "partial":
            needs_ops.append(ins.opname)
    return True, needs_ops


def analyze_folds(cfg: CFG, target: TargetModel) -> FoldResult:
    groups = sorted(
        (g for g in target.fold_groups if len(g["cats"]) <= target.max_fold_len),
        key=lambda g: -len(g["cats"]),
    )
    aggregated: dict[str, FoldCandidate] = {}
    site_count = 0

    for block in cfg.blocks:
        instrs = cfg.block_instructions(block)
        for segment in _split_segments(target, instrs):
            slots = _build_slots(target, segment)
            n = len(slots)
            p = 0
            while p < n:
                if not slots[p].first:  # stay on instruction boundaries
                    p += 1
                    continue
                match = _match_at(slots, p, n, groups, target)
                if match is None:
                    p = _next_boundary(slots, p, n)
                    continue
                group, length, insns, needs_ops = match
                _record(aggregated, group, insns, needs_ops, cfg)
                site_count += 1
                p += length

    candidates = sorted(aggregated.values(), key=lambda c: (c.name,))
    return FoldResult(candidates=candidates, site_count=site_count)


def _match_at(slots, p, n, groups, target):
    for group in groups:
        cats = group["cats"]
        length = len(cats)
        if p + length > n:
            continue
        if not slots[p + length - 1].last:  # must end on an instruction boundary
            continue
        if any(slots[p + k].cat != cats[k] for k in range(length)):
            continue
        if not _self_contained(slots, p, length, target, cats[-1]):
            continue
        insns = _covered_instructions(slots, p, length)
        ok, needs_ops = _passes_safety(insns, group, target)
        if not ok:
            continue
        return group, length, insns, needs_ops
    return None


def _next_boundary(slots: list[_Slot], p: int, n: int) -> int:
    q = p + 1
    while q < n and not slots[q].first:
        q += 1
    return q


def _record(aggregated: dict[str, FoldCandidate], group: dict,
            insns: list[Instr], needs_ops: list[str], cfg: CFG) -> None:
    name = group["name"]
    start_offset = insns[0].offset
    in_loop = any(cfg.is_in_loop(ins.offset) for ins in insns)
    candidate = aggregated.get(name)
    if candidate is None:
        candidate = FoldCandidate(
            name=name,
            opnames=[ins.opname for ins in insns],
            offsets=[],
            line=insns[0].line,
            in_loop=False,
            remediation=group.get("remediation", "hardware"),
            savings=group.get("savings"),
            needs_ops=[],
        )
        aggregated[name] = candidate
    candidate.offsets.append(start_offset)
    candidate.count += 1
    candidate.in_loop = candidate.in_loop or in_loop
    for op in needs_ops:
        if op not in candidate.needs_ops:
            candidate.needs_ops.append(op)
