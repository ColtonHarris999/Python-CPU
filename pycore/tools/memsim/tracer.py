"""Dynamic opcode tracer for PyCore memory-system analysis.

Runs a PyCore-subset program on real CPython 3.14 and records the retired
instruction stream plus PY_START / PY_RETURN markers, so a CALL that entered a
Python frame (including a recursive one) can be told from a builtin dispatch.
"""
from __future__ import annotations

import opcode as _op
import sys
import types
from dataclasses import dataclass, field

OPMAP = _op.opmap
OPNAME = _op.opname
CACHES = _op._inline_cache_entries


@dataclass
class Step:
    code_id: int
    offset: int
    opname: str
    arg: int
    enters_frame: bool = False   # this CALL pushed a Python frame
    pops_frame: bool = False     # this RETURN popped a Python frame
    callee_id: int = 0           # code object entered by this CALL


@dataclass
class Trace:
    steps: list[Step] = field(default_factory=list)
    codes: dict[int, types.CodeType] = field(default_factory=dict)


def _decode_at(co: types.CodeType, offset: int) -> tuple[str, int]:
    code = co.co_code
    op = code[offset]
    arg = code[offset + 1]
    back = offset - 2
    shift = 8
    while back >= 0 and code[back] == OPMAP["EXTENDED_ARG"]:
        arg |= code[back + 1] << shift
        shift += 8
        back -= 2
    return OPNAME[op], arg


def trace_module(module_code: types.CodeType, globals_ns: dict) -> Trace:
    tr = Trace()
    mon = sys.monitoring
    E = mon.events
    TOOL = mon.DEBUGGER_ID
    mon.use_tool_id(TOOL, "pycore-memsim")

    # Index of the last INSTRUCTION step, so PY_START/PY_RETURN can annotate it.
    state = {"last": -1, "depth": 0}

    def on_instruction(code, instruction_offset):
        cid = id(code)
        if cid not in tr.codes:
            tr.codes[cid] = code
        name, arg = _decode_at(code, instruction_offset)
        tr.steps.append(Step(cid, instruction_offset, name, arg))
        state["last"] = len(tr.steps) - 1
        return None

    def on_py_start(code, instruction_offset):
        i = state["last"]
        if i >= 0 and tr.steps[i].opname.startswith("CALL"):
            tr.steps[i].enters_frame = True
            tr.steps[i].callee_id = id(code)
            tr.codes.setdefault(id(code), code)
        return None

    def on_py_return(code, instruction_offset, retval):
        i = state["last"]
        if i >= 0 and tr.steps[i].opname.startswith("RETURN"):
            tr.steps[i].pops_frame = True
        return None

    try:
        mon.register_callback(TOOL, E.INSTRUCTION, on_instruction)
        mon.register_callback(TOOL, E.PY_START, on_py_start)
        mon.register_callback(TOOL, E.PY_RETURN, on_py_return)
        mon.set_events(TOOL, E.INSTRUCTION | E.PY_START | E.PY_RETURN)
        exec(module_code, globals_ns)
    finally:
        mon.set_events(TOOL, 0)
        for ev in (E.INSTRUCTION, E.PY_START, E.PY_RETURN):
            mon.register_callback(TOOL, ev, None)
        mon.free_tool_id(TOOL)
    return tr
