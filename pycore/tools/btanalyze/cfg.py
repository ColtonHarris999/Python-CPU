"""Control-flow graph + loop detection over a function's bytecode.

The analyzer only needs three things from control flow: basic-block boundaries
(so folds never cross them), and which offsets sit inside a loop (so the gap
analyzer can flag costly-in-loop hotspots). Loops are found structurally via
back-edges -- a jump whose target is at or before its own offset -- which needs
no trip counts and is exact for the scalar programs PyCore runs.
"""

from __future__ import annotations

import dis
import opcode
from dataclasses import dataclass, field


_JUMP_OPCODES = set(opcode.hasjrel) | set(opcode.hasjabs)
_TERMINATOR_OPNAMES = {"RETURN_VALUE", "RETURN_GENERATOR", "RAISE_VARARGS", "RERAISE"}


@dataclass(frozen=True)
class Instr:
    index: int
    offset: int
    opname: str
    arg: int | None
    argrepr: str
    line: int | None
    is_jump_target: bool
    jump_target: int | None


@dataclass(frozen=True)
class Block:
    block_id: int
    start_offset: int
    end_offset: int  # offset of the last instruction in the block (inclusive)
    start_index: int
    end_index: int  # index of the last instruction in the block (inclusive)


@dataclass
class CFG:
    instructions: list[Instr]
    leaders: set[int]
    blocks: list[Block]
    offset_to_block: dict[int, int] = field(default_factory=dict)
    back_edges: list[tuple[int, int]] = field(default_factory=list)
    in_loop_offsets: set[int] = field(default_factory=set)

    @property
    def loop_count(self) -> int:
        return len(self.back_edges)

    def is_in_loop(self, offset: int) -> bool:
        return offset in self.in_loop_offsets

    def block_instructions(self, block: Block) -> list[Instr]:
        return self.instructions[block.start_index : block.end_index + 1]


def _is_flow_instruction(ins: Instr) -> bool:
    return ins.jump_target is not None or ins.opname in _TERMINATOR_OPNAMES


def build_instructions(fn) -> list[Instr]:
    """Disassemble ``fn`` into our lightweight Instr records (no CACHE rows)."""
    result: list[Instr] = []
    for index, ins in enumerate(dis.get_instructions(fn)):
        jump_target = ins.jump_target if ins.opcode in _JUMP_OPCODES else None
        result.append(
            Instr(
                index=index,
                offset=ins.offset,
                opname=ins.opname,
                arg=ins.arg,
                argrepr=ins.argrepr,
                line=ins.line_number,
                is_jump_target=ins.is_jump_target,
                jump_target=jump_target,
            )
        )
    return result


def build_cfg(fn) -> CFG:
    instructions = build_instructions(fn)
    cfg = CFG(instructions=instructions, leaders=set(), blocks=[])
    if not instructions:
        return cfg

    offsets = [ins.offset for ins in instructions]
    offset_set = set(offsets)

    # --- leaders ---
    leaders: set[int] = {instructions[0].offset}
    for i, ins in enumerate(instructions):
        if ins.jump_target is not None and ins.jump_target in offset_set:
            leaders.add(ins.jump_target)
        if _is_flow_instruction(ins) and i + 1 < len(instructions):
            leaders.add(instructions[i + 1].offset)
    cfg.leaders = leaders

    # --- basic blocks ---
    blocks: list[Block] = []
    offset_to_block: dict[int, int] = {}
    current_start_index = 0
    for i, ins in enumerate(instructions):
        is_last = i == len(instructions) - 1
        next_is_leader = (not is_last) and instructions[i + 1].offset in leaders
        if is_last or next_is_leader:
            start = instructions[current_start_index]
            block = Block(
                block_id=len(blocks),
                start_offset=start.offset,
                end_offset=ins.offset,
                start_index=current_start_index,
                end_index=i,
            )
            for j in range(current_start_index, i + 1):
                offset_to_block[instructions[j].offset] = block.block_id
            blocks.append(block)
            current_start_index = i + 1
    cfg.blocks = blocks
    cfg.offset_to_block = offset_to_block

    # --- back-edges + in-loop offsets ---
    back_edges: list[tuple[int, int]] = []
    in_loop: set[int] = set()
    for ins in instructions:
        target = ins.jump_target
        if target is not None and target in offset_set and target <= ins.offset:
            back_edges.append((ins.offset, target))
            for off in offsets:
                if target <= off <= ins.offset:
                    in_loop.add(off)
    cfg.back_edges = back_edges
    cfg.in_loop_offsets = in_loop
    return cfg
