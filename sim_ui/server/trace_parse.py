"""Parse tb_sim_trace JSONL into UI session snapshots."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .decode import (
    MUT_KIND_NAMES,
    RECOVERABLE_TRAPS,
    TAG_NAMES,
    decode_entry_hex,
    opcode_name,
    trap_name,
)

# Opcodes treated as keypoints for scrubber filtering.
_KEYPOINT_OPS = {
    "CALL",
    "CALL_KW",
    "CALL_FUNCTION_EX",
    "RETURN_VALUE",
    "MAKE_FUNCTION",
    "BUILD_LIST",
    "BUILD_MAP",
    "BUILD_SET",
    "BUILD_TUPLE",
    "LIST_EXTEND",
    "LIST_APPEND",
    "DICT_UPDATE",
    "DICT_MERGE",
    "SET_UPDATE",
    "MAP_ADD",
    "SET_ADD",
    "FOR_ITER",
    "RAISE_VARARGS",
    "BINARY_OP",
    "STORE_SUBSCR",
    "DELETE_SUBSCR",
}


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

    by_step: dict[int, list[dict[str, Any]]] = {}
    for ev in events:
        by_step.setdefault(int(ev.get("step", 0)), []).append(ev)
    for step in steps:
        step["events"] = by_step.get(int(step["step"]), [])
        # Excore mailbox snapshot from nearest prior trap_req on this step.
        mailbox = None
        for ev in step["events"]:
            if ev.get("kind") == "trap_req":
                mailbox = {
                    "code": ev.get("code"),
                    "code_name": ev.get("code_name"),
                    "pc": ev.get("pc"),
                    "opcode": ev.get("opcode"),
                    "entries": ev.get("entries") or [],
                }
        step["excore"] = {
            "active": step.get("mem_owner") == "EXCORE",
            "mailbox": mailbox,
            "last_trap_code": (mailbox or {}).get("code"),
            "parked": step.get("mem_owner") != "EXCORE",
        }
        step["keypoint"] = _is_keypoint(step)

    return {
        "meta": meta,
        "steps": steps,
        "events": events,
        "end": end or {"status": "ERROR"},
        "step_count": len(steps),
    }


def filter_keypoints(steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep CALL/RETURN/container/trap-adjacent steps + first/last."""
    if not steps:
        return steps
    out: list[dict[str, Any]] = []
    for i, step in enumerate(steps):
        if i == 0 or i == len(steps) - 1 or step.get("keypoint") or step.get("events"):
            out.append(step)
    # Re-index display step for scrubber while keeping original step id.
    return out


def _is_keypoint(step: dict[str, Any]) -> bool:
    if step.get("events"):
        return True
    op = step.get("opcode") or ""
    if op in _KEYPOINT_OPS:
        return True
    if op.startswith("BUILD_") or op.startswith("POP_JUMP"):
        return True
    return False


def _enrich_step(rec: dict[str, Any]) -> dict[str, Any]:
    op = int(rec.get("opcode", 0))
    stack = [decode_entry_hex(h) for h in rec.get("stack", [])]
    locals_raw = [decode_entry_hex(h) for h in rec.get("locals", [])]
    rf_raw = rec.get("rf") or {}
    rf = {str(k): decode_entry_hex(v) for k, v in rf_raw.items()}
    frames = []
    for fr in rec.get("frames", []):
        locals_fr = [decode_entry_hex(h) for h in (fr.get("locals_raw") or [])]
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
                "locals_raw": locals_fr,
            }
        )
    heap_delta = []
    for root in rec.get("heap_roots") or []:
        heap_delta.append(_root_summary(root))
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
        "tos_base": int(rec.get("tos_base", 32)),
        "frame_depth": int(rec.get("frame_depth", 0)),
        "mem_owner": "EXCORE" if mem_owner else "PYCORE",
        "heap_ptr": int(rec.get("heap_ptr", 0)),
        "cur_code": int(rec.get("cur_code", 0)),
        "stack": stack,
        "locals_window": locals_raw,
        "rf": rf,
        "frames": frames,
        "heap_delta": heap_delta,
        "trap": None,
        "excore": {"active": bool(mem_owner), "mailbox": None},
        "events": [],
        "keypoint": False,
        "stdout_like": [],
    }


def _root_summary(root: dict[str, Any]) -> dict[str, Any]:
    tag = int(root.get("tag") or 0)
    addr = int(root.get("addr") or 0)
    kind_id = root.get("kind")
    contam = root.get("contaminated")
    hdr_lo = int(root.get("hdr_lo") or 0)
    hdr_hi = int(root.get("hdr_hi") or 0)
    tag_name = TAG_NAMES.get(tag, f"TAG_{tag}")
    kind_name = None
    summary = f"{tag_name}@{addr:#x}"
    if kind_id is not None:
        kind_name = MUT_KIND_NAMES.get(int(kind_id), f"KIND({kind_id})")
        if kind_name == "LIST":
            summary = f"list len={hdr_lo} cap={hdr_hi}"
        elif kind_name in ("DICT", "SET"):
            summary = f"{kind_name.lower()} used={hdr_lo} slots={hdr_hi}"
        else:
            summary = f"{kind_name.lower()}@{addr:#x}"
        if contam:
            summary += " contaminated"
    elif tag_name == "TUPLE":
        summary = f"tuple len={hdr_hi} @{addr:#x}"
    elif tag_name == "CODE_OBJECT":
        summary = f"code@{addr:#x}"
    return {
        "addr": hex(addr),
        "addr_int": addr,
        "tag": tag_name,
        "kind": kind_name,
        "contaminated": bool(contam) if contam is not None else None,
        "summary": summary,
        "routing_note": (
            "bulk on pycore — contaminated"
            if contam and kind_name in ("DICT", "SET")
            else None
        ),
    }


def _enrich_event(rec: dict[str, Any]) -> dict[str, Any]:
    code = int(rec.get("code", 0))
    entries = [decode_entry_hex(h) for h in (rec.get("entries") or [])]
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
        "entry_count": int(rec.get("entry_count") or 0),
        "entries": entries,
    }


def _enrich_end(rec: dict[str, Any]) -> dict[str, Any]:
    ret_tag = rec.get("return_tag")
    ret_val = rec.get("return_value")
    decoded = None
    if ret_tag is not None and ret_val is not None:
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
    func_names_by_code: dict[int, str] | None = None,
) -> None:
    """Attach co_varnames labels / function names to frame locals."""
    func_names_by_code = func_names_by_code or {}
    for step in steps:
        for fr in step.get("frames") or []:
            code = int(fr.get("code_addr") or 0)
            names = varnames_by_code.get(code, [])
            raw = fr.get("locals_raw") or (
                step.get("locals_window") if fr.get("current") else []
            )
            labeled: dict[str, Any] = {}
            for i, entry in enumerate(raw or []):
                if entry.get("display") == "UNINIT" and i >= len(names):
                    continue
                key = names[i] if i < len(names) else f"local[{i}]"
                labeled[key] = entry
            fr["locals"] = labeled
            fr["func"] = func_names_by_code.get(code) or f"code@{code:#x}"
            if names:
                fr["nlocals_named"] = len(names)
