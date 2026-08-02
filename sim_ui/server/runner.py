"""Build image + run traced two-core Verilator sim for a UI session."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .decode import DmemImage, decode_heap_object, parse_entry_hex
from .disasm import disasm_program_hex
from .trace_parse import label_frames_with_varnames, parse_trace_jsonl

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS = REPO_ROOT / "pycore" / "tools"
BUILD_ROOT = REPO_ROOT / "build" / "sim_ui"
DEFAULT_MAX_CYCLES = 200_000
DEFAULT_MAX_SOURCE_BYTES = 200_000


@dataclass
class Session:
    id: str
    dir: Path
    status: str = "pending"
    error: str | None = None
    source: str = ""
    entry: str = "managed_entry"
    max_cycles: int = DEFAULT_MAX_CYCLES
    created_at: float = field(default_factory=time.time)
    result: dict[str, Any] | None = None
    steps: list[dict[str, Any]] = field(default_factory=list)
    events: list[dict[str, Any]] = field(default_factory=list)
    disasm: list[dict[str, Any]] = field(default_factory=list)
    end: dict[str, Any] | None = None
    dmem_final: DmemImage | None = None


_SESSIONS: dict[str, Session] = {}


def session_get(sid: str) -> Session | None:
    return _SESSIONS.get(sid)


def list_example_sources() -> list[dict[str, str]]:
    examples = [
        ("smoke", "Smoke return 42", "pycore/programs/img_smoke.py"),
        ("recursion", "Fibonacci recursion (frames)", "pycore/programs/img_recursion.py"),
        ("call_chain", "Nested call chain", "pycore/programs/img_call_chain.py"),
        ("containers", "List/dict/tuple basics", "pycore/programs/img_containers.py"),
        ("list_extend", "LIST_EXTEND → excore mailbox", "pycore/programs/img_list_extend.py"),
        ("dict_update", "DICT_UPDATE bulk trap", "pycore/programs/img_dict_update.py"),
        ("dict_merge", "DICT_MERGE bulk trap", "pycore/programs/img_dict_merge.py"),
        ("set_update", "SET_UPDATE bulk trap", "pycore/programs/img_set_update.py"),
        ("dict_update_obj", "Contaminated dict update (pycore)", "pycore/programs/img_dict_update_obj.py"),
        ("undef_global", "Fatal NAME/global trap", "pycore/programs/img_undef_global.py"),
    ]
    out = []
    for key, title, rel in examples:
        path = REPO_ROOT / rel
        if path.is_file():
            out.append(
                {
                    "id": key,
                    "title": title,
                    "path": rel,
                    "source": path.read_text(encoding="utf-8"),
                }
            )
    return out


def health_check() -> dict[str, Any]:
    py_ver = sys.version_info
    verilator = shutil.which("verilator")
    fw = REPO_ROOT / "build" / "excore_fw" / "list_grow.hex"
    return {
        "ok": py_ver[:2] == (3, 14) and verilator is not None,
        "python": f"{py_ver.major}.{py_ver.minor}.{py_ver.micro}",
        "python_3_14": py_ver[:2] == (3, 14),
        "verilator": verilator is not None,
        "verilator_path": verilator,
        "excore_fw": fw.is_file(),
        "excore_fw_path": str(fw) if fw.is_file() else None,
        "two_core": True,
        "repo_root": str(REPO_ROOT),
    }


def _ensure_fw() -> Path:
    fw = REPO_ROOT / "build" / "excore_fw" / "list_grow.hex"
    if fw.is_file():
        return fw
    subprocess.run(
        ["make", "excore-fw"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    if not fw.is_file():
        raise RuntimeError("excore-fw build failed — missing list_grow.hex")
    return fw


def _build_image(session_dir: Path, source_text: str, entry: str) -> dict[str, Any]:
    if str(TOOLS) not in sys.path:
        sys.path.insert(0, str(TOOLS))
    from image_from_source import (  # type: ignore
        build_image_from_source_text,
        write_image_outputs,
    )
    from run_image_test import expected_tag_value, host_entry_result  # type: ignore

    src_path = session_dir / "source.py"
    src_path.write_text(source_text, encoding="utf-8")

    expected: dict[str, Any] = {"available": False}
    try:
        host_val = host_entry_result(src_path, entry)
        tag, value = expected_tag_value(host_val)
        expected = {
            "available": True,
            "tag": tag,
            "value": value,
            "host_display": repr(host_val),
        }
    except Exception as exc:  # noqa: BLE001
        expected = {"available": False, "error": str(exc)}

    result = build_image_from_source_text(source_text, filename=str(src_path))
    write_image_outputs(
        result,
        program_hex=session_dir / "program.hex",
        dmem_hex=session_dir / "dmem.hex",
        string_hex=session_dir / "string_mem.hex",
        meta=session_dir / "image.meta",
        expected_tag=expected.get("tag") if expected.get("available") else None,
        expected_value=expected.get("value") if expected.get("available") else None,
    )
    meta: dict[str, str] = {}
    for line in (session_dir / "image.meta").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
    return {"meta": meta, "expected": expected}


def _run_verilator_trace(
    session_dir: Path,
    *,
    heap_init_ptr: int,
    max_cycles: int,
    expected: dict[str, Any],
) -> None:
    fw = _ensure_fw()
    rtl_srcs = [
        "pycore/rtl/pycore_tag_decode.sv",
        "pycore/rtl/pycore_promote.sv",
        "pycore/rtl/pycore_int_alu.sv",
        "pycore/rtl/pycore_mul.sv",
        "pycore/rtl/pycore_div.sv",
        "pycore/rtl/pycore_fpu.sv",
        "pycore/rtl/pycore_complex_alu.sv",
        "pycore/rtl/pycore_string_mem.sv",
        "pycore/rtl/pycore_exec.sv",
        "pycore/rtl/pycore_regfile.sv",
        "pycore/rtl/pycore_fetch.sv",
        "pycore/rtl/pycore_decode.sv",
        "pycore/rtl/pycore_branch.sv",
        "pycore/rtl/pycore_trap.sv",
        "pycore/rtl/pycore_frame.sv",
        "pycore/rtl/pycore_mem_block.sv",
        "pycore/rtl/pycore_mem_bank.sv",
        "pycore/rtl/pycore_imem.sv",
        "pycore/rtl/pycore_dmem.sv",
        "pycore/rtl/pycore_mem_stage.sv",
        "pycore/rtl/pycore_core.sv",
        "pycore/rtl/pycore_system.sv",
        "excore/rtl/excore_cpu.sv",
        "excore/rtl/excore_mmio.sv",
        "excore/rtl/trap_mailbox.sv",
        "pycore/rtl/pycore_excore_system.sv",
        "pycore/tb/tb_sim_trace.sv",
    ]
    mdir = session_dir / "verilator"
    mdir.mkdir(parents=True, exist_ok=True)
    prog = session_dir / "program.hex"
    dmem = session_dir / "dmem.hex"
    smem = session_dir / "string_mem.hex"
    trace = session_dir / "trace.jsonl"
    dmem_final = session_dir / "dmem_final.hex"

    g_args = [
        f'-GPROG_HEX="{prog}"',
        f'-GSTRING_HEX="{smem}"',
        f'-GDMEM_HEX="{dmem}"',
        f'-GFW_HEX="{fw}"',
        f'-GTRACE_JSONL="{trace}"',
        f'-GDMEM_FINAL_HEX="{dmem_final}"',
        "-GBOOT_EN=1",
        "-GCHECK_ENTRY_RETURN=1",
        f"-GHEAP_INIT_PTR={heap_init_ptr}",
        f"-GMAX_CYCLES={max_cycles}",
    ]
    if expected.get("available"):
        g_args.append("-GHAS_EXPECTED=1")
        g_args.append(f"-GEXPECTED_TAG=4'd{expected['tag']}")
        g_args.append(f"-GEXPECTED_VALUE=128'd{expected['value']}")

    cmd = [
        "verilator",
        "-sv",
        "--binary",
        "--timing",
        "+incdir+pycore/rtl",
        "+incdir+excore/rtl/singlecore",
        "--top-module",
        "tb_sim_trace",
        *g_args,
        "--Mdir",
        str(mdir),
        "-Wall",
        "-Wno-fatal",
        *rtl_srcs,
    ]
    build = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    (session_dir / "verilator_build.log").write_text(
        build.stdout + "\n" + build.stderr, encoding="utf-8"
    )
    if build.returncode != 0:
        raise RuntimeError(
            "Verilator build failed.\n" + (build.stderr or build.stdout)[-4000:]
        )

    exe = mdir / "Vtb_sim_trace"
    if not exe.is_file():
        # Some Verilator versions nest the binary.
        candidates = list(mdir.glob("**/Vtb_sim_trace"))
        if not candidates:
            raise RuntimeError("Verilator binary Vtb_sim_trace not found")
        exe = candidates[0]

    run = subprocess.run(
        [str(exe)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=max(120, max_cycles // 1000 + 60),
    )
    (session_dir / "sim_run.log").write_text(
        run.stdout + "\n" + run.stderr, encoding="utf-8"
    )
    if not trace.is_file():
        raise RuntimeError(
            "Simulation produced no trace.jsonl.\n"
            + (run.stderr or run.stdout)[-4000:]
        )


def _extract_varnames(dmem: DmemImage | None, code_addrs: set[int]) -> dict[int, list[str]]:
    """Best-effort co_varnames extraction from final dmem code objects."""
    from .decode import (
        CODE_FIELD_CO_VARNAMES,
        TAG_SHORT_STR,
        TAG_TUPLE,
        decode_entry,
    )

    out: dict[int, list[str]] = {}
    if dmem is None:
        return out
    for addr in code_addrs:
        try:
            # Field 5 = co_varnames at addr + 5*32
            f_addr = addr + CODE_FIELD_CO_VARNAMES * 32
            tag_word = dmem.read_word(f_addr + 16)
            val = dmem.read_word(f_addr)
            tag = tag_word & 0xF
            if tag != TAG_TUPLE:
                continue
            size = (val >> 64) & 0xFFFFFFFF
            taddr = val & ((1 << 64) - 1)
            names: list[str] = []
            for i in range(min(size, 32)):
                e_tag, e_val = dmem.read_entry_pair(taddr + i * 32)
                dec = decode_entry(e_tag, e_val)
                if e_tag == TAG_SHORT_STR:
                    # display is repr(s); strip quotes
                    disp = dec.get("display", "")
                    if isinstance(disp, str) and len(disp) >= 2 and disp[0] in "'\"":
                        names.append(ast_literal(disp))
                    else:
                        names.append(str(disp))
                else:
                    names.append(dec.get("display", f"v{i}"))
            out[addr] = names
        except Exception:
            continue
    return out


def ast_literal(s: str) -> str:
    try:
        import ast

        v = ast.literal_eval(s)
        return v if isinstance(v, str) else s
    except Exception:
        return s.strip("'\"")


def create_session(
    source: str,
    *,
    entry: str = "managed_entry",
    max_cycles: int = DEFAULT_MAX_CYCLES,
) -> Session:
    if len(source.encode("utf-8")) > DEFAULT_MAX_SOURCE_BYTES:
        raise ValueError(f"source exceeds {DEFAULT_MAX_SOURCE_BYTES} bytes")
    if max_cycles < 1000 or max_cycles > 5_000_000:
        raise ValueError("max_cycles out of allowed range [1000, 5000000]")
    if not entry.isidentifier():
        raise ValueError("entry must be a valid identifier")

    sid = uuid.uuid4().hex[:12]
    session_dir = BUILD_ROOT / sid
    session_dir.mkdir(parents=True, exist_ok=True)
    sess = Session(
        id=sid,
        dir=session_dir,
        source=source,
        entry=entry,
        max_cycles=max_cycles,
        status="running",
    )
    _SESSIONS[sid] = sess

    try:
        built = _build_image(session_dir, source, entry)
        heap_init = int(built["meta"].get("HEAP_INIT_PTR", "0"))
        _run_verilator_trace(
            session_dir,
            heap_init_ptr=heap_init,
            max_cycles=max_cycles,
            expected=built["expected"],
        )
        parsed = parse_trace_jsonl(session_dir / "trace.jsonl")
        dmem_final_path = session_dir / "dmem_final.hex"
        dmem = DmemImage.from_hex_file(dmem_final_path) if dmem_final_path.is_file() else None
        code_addrs = {int(s.get("cur_code") or 0) for s in parsed["steps"]}
        code_addrs |= {
            int(fr.get("code_addr") or 0)
            for s in parsed["steps"]
            for fr in (s.get("frames") or [])
        }
        code_addrs.discard(0)
        varnames = _extract_varnames(dmem, code_addrs)
        label_frames_with_varnames(parsed["steps"], varnames)

        sess.steps = parsed["steps"]
        sess.events = parsed["events"]
        sess.end = parsed["end"]
        sess.disasm = disasm_program_hex(session_dir / "program.hex")
        sess.dmem_final = dmem
        sess.result = {
            "expected": built["expected"],
            "meta": built["meta"],
            "end": sess.end,
            "step_count": parsed["step_count"],
            "event_count": len(parsed["events"]),
        }
        sess.status = "ready"
        # Persist summary for restarts.
        (session_dir / "session.json").write_text(
            json.dumps(
                {
                    "id": sid,
                    "entry": entry,
                    "max_cycles": max_cycles,
                    "result": sess.result,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    except Exception as exc:  # noqa: BLE001
        sess.status = "error"
        sess.error = str(exc)
        (session_dir / "error.txt").write_text(str(exc), encoding="utf-8")
    return sess


def get_step(sess: Session, n: int) -> dict[str, Any]:
    if n < 0 or n >= len(sess.steps):
        raise IndexError(f"step {n} out of range 0..{len(sess.steps)-1}")
    return sess.steps[n]


def get_heap(sess: Session, addr: int, step: int | None = None) -> dict[str, Any]:
    if sess.dmem_final is None:
        raise RuntimeError("no final dmem image available")
    # Find a tagged handle on the requested step stack/locals pointing at addr,
    # else try MUT_COLLEC/TUPLE/CODE decode assuming MUT_COLLEC list.
    tag = None
    value = None
    if step is not None and 0 <= step < len(sess.steps):
        snap = sess.steps[step]
        for entry in list(snap.get("stack") or []) + list(snap.get("locals_window") or []):
            if entry.get("addr") == addr:
                tag = entry.get("tag_id")
                raw = entry.get("raw", "0")
                _, value = parse_entry_hex(raw[2:] if raw.startswith("0x") else raw)
                break
    if tag is None:
        # Fallback: treat as list object header address under MUT_COLLEC.
        from .decode import TAG_MUT_COLLEC, make_list

        tag, value = make_list(addr)
    return decode_heap_object(sess.dmem_final, tag, value)


def prune_sessions(ttl_s: float = 3600.0, max_keep: int = 20) -> None:
    now = time.time()
    items = sorted(_SESSIONS.values(), key=lambda s: s.created_at, reverse=True)
    for i, sess in enumerate(items):
        stale = (now - sess.created_at) > ttl_s or i >= max_keep
        if stale:
            _SESSIONS.pop(sess.id, None)
