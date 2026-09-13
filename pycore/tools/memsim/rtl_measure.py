"""Ingest tb_container performance counters and compare them to memsim.

P9: the RTL already prints L1I/L1D/CODC/GIC/frame counters at the end of
every image run. This module parses those lines, can launch `Vtb_container`
on a source file, and produces the per-structure rates memsim predicts for
the shipped sizes (L1 8 KB/64 B/4-way, CODC 4/2, GIC 16/2).
"""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, field

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "pycore" / "tools"))

from cachesim import Cache, DirectTagCache, codc_set_index, gic_set_index  # noqa: E402
import model as M  # noqa: E402
from run import imem_stream, run_program  # noqa: E402

SIM_IMG = ROOT / "build" / "sim_img" / "Vtb_container"
ENSURE_SIM = ROOT / "tools" / "ensure_sim.py"

L1I_RE = re.compile(r"L1I hits=(\d+) misses=(\d+)")
L1D_RE = re.compile(
    r"L1D hits=(\d+) misses=(\d+) wb=(\d+) "
    r"frame_hits=(\d+) frame_misses=(\d+)"
)
CODC_RE = re.compile(r"CODC hits=(\d+) misses=(\d+) fills=(\d+) flushes=(\d+)")
GIC_RE = re.compile(r"GIC hits=(\d+) misses=(\d+) fills=(\d+) flushes=(\d+)")
PASS_RE = re.compile(r"PASS:.*cycles=(\d+)")
FETCH_RE = re.compile(r"fetch mem_req=(\d+) buf_hit=(\d+)")

# Image programs small enough for RTL and overlapping the memsim set.
RTL_PROGRAMS = [
    ROOT / "pycore/programs/img_recursion.py",
    ROOT / "pycore/programs/img_deep_callgraph.py",
    ROOT / "pycore/programs/img_branchy.py",
    ROOT / "pycore/programs/img_globals_accum.py",
    ROOT / "pycore/programs/img_str_subscr_long.py",
    HERE / "bench" / "bench_strings.py",
]


@dataclass
class Counters:
    l1i_hits: int = 0
    l1i_misses: int = 0
    l1d_hits: int = 0
    l1d_misses: int = 0
    l1d_wb: int = 0
    frame_hits: int = 0
    frame_misses: int = 0
    codc_hits: int = 0
    codc_misses: int = 0
    codc_fills: int = 0
    codc_flushes: int = 0
    gic_hits: int = 0
    gic_misses: int = 0
    gic_fills: int = 0
    gic_flushes: int = 0
    cycles: int = 0
    fetch_mem_req: int = 0
    fetch_buf_hit: int = 0
    passed: bool = False
    raw: str = ""

    def rate(self, hits: int, misses: int) -> float:
        tot = hits + misses
        return hits / tot if tot else 0.0

    @property
    def l1i_hit_rate(self) -> float:
        return self.rate(self.l1i_hits, self.l1i_misses)

    @property
    def l1d_hit_rate(self) -> float:
        return self.rate(self.l1d_hits, self.l1d_misses)

    @property
    def frame_hit_rate(self) -> float:
        return self.rate(self.frame_hits, self.frame_misses)

    @property
    def codc_hit_rate(self) -> float:
        return self.rate(self.codc_hits, self.codc_misses)

    @property
    def gic_hit_rate(self) -> float:
        return self.rate(self.gic_hits, self.gic_misses)


def parse_counters(text: str) -> Counters:
    """Parse the lines `tb_container.sv` prints at the end of an image run."""
    c = Counters(raw=text)
    m = L1I_RE.search(text)
    if m:
        c.l1i_hits, c.l1i_misses = int(m.group(1)), int(m.group(2))
    m = L1D_RE.search(text)
    if m:
        c.l1d_hits = int(m.group(1))
        c.l1d_misses = int(m.group(2))
        c.l1d_wb = int(m.group(3))
        c.frame_hits = int(m.group(4))
        c.frame_misses = int(m.group(5))
    m = CODC_RE.search(text)
    if m:
        c.codc_hits = int(m.group(1))
        c.codc_misses = int(m.group(2))
        c.codc_fills = int(m.group(3))
        c.codc_flushes = int(m.group(4))
    m = GIC_RE.search(text)
    if m:
        c.gic_hits = int(m.group(1))
        c.gic_misses = int(m.group(2))
        c.gic_fills = int(m.group(3))
        c.gic_flushes = int(m.group(4))
    m = PASS_RE.search(text)
    if m:
        c.cycles = int(m.group(1))
        c.passed = True
    m = FETCH_RE.search(text)
    if m:
        c.fetch_mem_req = int(m.group(1))
        c.fetch_buf_hit = int(m.group(2))
    return c


def _parse_meta(path: pathlib.Path) -> dict[str, str]:
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def ensure_sim() -> pathlib.Path:
    if SIM_IMG.is_file() and os.access(SIM_IMG, os.X_OK):
        return SIM_IMG
    subprocess.check_call(["python3", str(ENSURE_SIM), "img"], cwd=ROOT)
    if not SIM_IMG.is_file():
        raise FileNotFoundError(f"simulator missing: {SIM_IMG}")
    return SIM_IMG


def run_rtl(
    source: pathlib.Path,
    *,
    cache_en: int = 1,
    mem_latency: int = 4,
    max_cycles: int = 200_000,
    build_dir: pathlib.Path | None = None,
) -> Counters:
    """Build an image and run the shared `Vtb_container`, returning counters."""
    sys.path.insert(0, str(ROOT / "pycore" / "tools"))
    from run_image_test import run_image_test  # noqa: PLC0415

    sim = ensure_sim()
    work = build_dir or (ROOT / "build" / "memsim_rtl" / source.stem)
    work.mkdir(parents=True, exist_ok=True)
    program_hex = work / "program.hex"
    dmem_hex = work / "dmem.hex"
    meta_path = work / "image.meta"
    run_image_test(
        source=source,
        entry="managed_entry",
        program_hex=program_hex,
        dmem_hex=dmem_hex,
        meta=meta_path,
    )
    meta = _parse_meta(meta_path)
    cmd = [
        str(sim),
        f"+PROG_HEX={program_hex.resolve()}",
        f"+DMEM_HEX={dmem_hex.resolve()}",
        "+BOOT_EN=1",
        "+CHECK_ENTRY_RETURN=1",
        f"+HEAP_INIT_PTR={meta['HEAP_INIT_PTR']}",
        f"+EXPECTED_TAG={meta['EXPECTED_TAG']}",
        f"+EXPECTED_VALUE={meta['EXPECTED_VALUE']}",
        f"+MAX_CYCLES={max_cycles}",
        f"+CACHE_EN={cache_en}",
        f"+MEM_LATENCY={mem_latency}",
    ]
    proc = subprocess.run(
        cmd, cwd=ROOT, text=True, capture_output=True, check=False
    )
    text = (proc.stdout or "") + (proc.stderr or "")
    ctr = parse_counters(text)
    if proc.returncode != 0 or not ctr.passed:
        ctr.passed = False
        ctr.raw = text
    return ctr


def gic_key(st) -> tuple:
    namei = (st.arg >> 1) if st.opname == "LOAD_GLOBAL" else st.arg
    return (st.code_id, namei)


def codc_addr(cost) -> int | None:
    codeacc = [a for a in cost.accesses if a.cls == M.C_CODE]
    if not codeacc:
        return None
    if cost.opname.startswith("CALL"):
        return codeacc[0].addr
    if cost.opname.startswith("RETURN"):
        return codeacc[0].addr - 32
    return codeacc[0].addr


def model_rates(result: dict) -> dict[str, float | int]:
    """Shipped-size predictions from a memsim `run_program` result."""
    l1i = Cache(8192, 64, 4, name="L1I")
    l1d = Cache(8192, 64, 4, name="L1D")
    frame = Cache(8192, 64, 4, name="L1D-frame")
    gc = DirectTagCache(16, 2, name="GIC", index_fn=gic_set_index)
    dc = DirectTagCache(4, 2, name="CODC", index_fn=codc_set_index)
    for a in imem_stream(result["_lay"], result["_costs"], result["_steps"]):
        l1i.access(a)
    for co, st in zip(result["_costs"], result["_steps"]):
        for acc in co.accesses:
            l1d.access(acc.addr)
            if acc.cls == M.C_FRAME:
                frame.access(acc.addr)
        if st.opname in ("STORE_NAME", "STORE_GLOBAL"):
            gc.flush()
        elif st.opname in ("LOAD_GLOBAL", "LOAD_NAME"):
            gc.access(gic_key(st))
        key = codc_addr(co)
        if key is not None:
            dc.access(key)
    return {
        "l1i_hit_rate": l1i.hit_rate,
        "l1i_hits": l1i.hits,
        "l1i_misses": l1i.misses,
        "l1d_hit_rate": l1d.hit_rate,
        "l1d_hits": l1d.hits,
        "l1d_misses": l1d.misses,
        "frame_hit_rate": frame.hit_rate,
        "frame_hits": frame.hits,
        "frame_misses": frame.misses,
        "codc_hit_rate": dc.hit_rate,
        "codc_hits": dc.hits,
        "codc_misses": dc.misses,
        "gic_hit_rate": gc.hit_rate,
        "gic_hits": gc.hits,
        "gic_misses": gc.misses,
        "gic_flushes": gc.invalidations,
        "dmem_accesses": result["dmem_accesses"],
        "str_accesses": sum(
            1 for c in result["_costs"] for a in c.accesses if a.cls == M.C_STR
        ),
    }


def disagree(model: float, rtl: float, points: float = 3.0) -> bool:
    """True when hit-rate percentages differ by more than `points`."""
    return abs(100.0 * model - 100.0 * rtl) > points
