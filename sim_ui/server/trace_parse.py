"""Parse tb_sim_trace JSONL into UI session snapshots."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .decode import (
    RECOVERABLE_TRAPS,
    decode_entry_hex,
    opcode_name,
    trap_name,
)


def parse_trace_jsonl(path: Path) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    steps: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    end: dict[str, Any] | None = None

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        kind = rec.get("t")
        if kind == "meta":
            meta = rec
        elif kind == "step":
            steps.append(_enrich_step(rec))
        elif kind == "event":
            events.append(_enrich_event(rec))
        elif kind == "end":
            end = _enrich_end(rec)

    # Attach events to nearest step index for the UI lane.
    by_step: dict[int, list[dict[str, Any]]] = {}
    for ev in events:
        by_step.setdefault(int(ev.get("step", 0)), []).append(ev)
    for step in steps:
        step["events"] = by_step.get(int(step["step"]), [])

    return {
        "meta": meta,
        "steps": steps,
        "events": events,
        "end": end or {"status": "ERROR"},
        "step_count": len(steps),
    }


def _enrich_step(rec: dict[str, Any]) -> dict[str, Any]:
    op = int(rec.get("opcode", 0))
    stack = [decode_entry_hex(h) for h in rec.get("stack", [])]
    locals_raw = [decode_entry_hex(h) for h in rec.get("locals", [])]
    frames = []
    for fr in rec.get("frames", []):
        frames.append(
            {
                "depth": fr.get("depth"),
                "pc_return": fr.get("pc_return"),
                "tos_base": fr.get("tos_base"),
                "locals_base": fr.get("locals_base"),
                "code_addr": fr.get("code_addr"),
                "current": bool(fr.get("current")),
                "func": None,
                "locals": {},
            }
        )
    mem_owner = int(rec.get("mem_owner", 0))
    return {
        "step": int(rec.get("step", 0)),
        "cycle": int(rec.get("cycle", 0)),
        "pc": int(rec.get("pc", 0)),
        "opcode": opcode_name(op),
        "opcode_id": op,
        "oparg": int(rec.get("oparg", 0)),
        "state": rec.get("state", ""),
        "tos": int(rec.get("tos", 0)),
        "locals_base": int(rec.get("locals_base", 0)),
        "frame_depth": int(rec.get("frame_depth", 0)),
        "mem_owner": "EXCORE" if mem_owner else "PYCORE",
        "heap_ptr": int(rec.get("heap_ptr", 0)),
        "cur_code": int(rec.get("cur_code", 0)),
        "stack": stack,
        "locals_window": locals_raw,
        "frames": frames,
        "excore": {
            "active": bool(mem_owner),
            "mailbox": None,
        },
        "events": [],
    }


def _enrich_event(rec: dict[str, Any]) -> dict[str, Any]:
    code = int(rec.get("code", 0))
    return {
        "step": int(rec.get("step", 0)),
        "cycle": int(rec.get("cycle", 0)),
        "kind": rec.get("kind"),
        "code": code,
        "code_name": trap_name(code),
        "recoverable": code in RECOVERABLE_TRAPS,
        "pc": int(rec.get("pc", 0)),
        "opcode": opcode_name(int(rec.get("opcode", 0))),
        "arg": int(rec.get("arg", 0)),
        "mem_owner": "EXCORE" if int(rec.get("mem_owner", 0)) else "PYCORE",
    }


def _enrich_end(rec: dict[str, Any]) -> dict[str, Any]:
    ret_tag = rec.get("return_tag")
    ret_val = rec.get("return_value")
    decoded = None
    if ret_tag is not None and ret_val is not None:
        # return_value is 128-bit hex without tag; rebuild entry hex.
        tag = int(ret_tag)
        val = int(str(ret_val), 16)
        entry_hex = f"{(tag << 128) | val:033x}"
        decoded = decode_entry_hex(entry_hex)
    trap = rec.get("trap_code")
    return {
        "status": rec.get("status", "ERROR"),
        "cycles": int(rec.get("cycles", 0)),
        "opcodes": int(rec.get("opcodes", 0)),
        "trap_req_count": int(rec.get("trap_req_count", 0)),
        "trap_code": trap,
        "trap_name": trap_name(trap) if trap else None,
        "return_value": decoded,
        "expected_match": rec.get("expected_match"),
        "cpo": (
            (rec.get("cycles", 0) / rec["opcodes"])
            if rec.get("opcodes")
            else None
        ),
    }


def label_frames_with_varnames(
    steps: list[dict[str, Any]],
    varnames_by_code: dict[int, list[str]],
) -> None:
    """Attach co_varnames labels to frame locals when available."""
    for step in steps:
        code = int(step.get("cur_code") or 0)
        names = varnames_by_code.get(code, [])
        locals_window = step.get("locals_window") or []
        labeled: dict[str, Any] = {}
        for i, entry in enumerate(locals_window):
            key = names[i] if i < len(names) else f"local[{i}]"
            # Skip trailing UNINIT-only padding for display.
            if entry.get("display") == "UNINIT" and i >= len(names):
                continue
            labeled[key] = entry
        for fr in step.get("frames") or []:
            if fr.get("current"):
                fr["locals"] = labeled
                if names:
                    # Prefer first varname-bearing function name unknown; keep code addr.
                    fr["func"] = f"code@{code:#x}"
                else:
                    fr["func"] = f"code@{code:#x}"
            else:
                fr["func"] = f"code@{int(fr.get('code_addr') or 0):#x}"
