"""Text reports for one program and for a suite."""

from __future__ import annotations

import math


def _n(value) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:,.1f}"
    return f"{value:,}"


def _pct(rate) -> str:
    if rate is None:
        return "-"
    return f"{100.0 * rate:.1f}%"


def _dur_ns(ns) -> str:
    if ns is None:
        return "-"
    if ns < 1_000:
        return f"{ns:.0f} ns"
    if ns < 1_000_000:
        return f"{ns / 1e3:.1f} us"
    if ns < 1_000_000_000:
        return f"{ns / 1e6:.2f} ms"
    return f"{ns / 1e9:.3f} s"


def _phase_line(name: str, phase: dict | None) -> str:
    if not phase:
        return f"  {name:<16}{'-':>14}"
    caches = phase["caches"]
    return (
        f"  {name:<16}{_n(phase['cycles']):>14}"
        f"{_n(phase['events']['Ir']):>14}"
        f"{_pct(caches['l1i']['hit_rate']):>10}"
        f"{_pct(caches['l1d']['hit_rate']):>10}"
        f"{_pct(caches['llc']['hit_rate']):>10}"
        f"{_dur_ns(phase['simulated_ns']):>12}"
    )


def render_program(record: dict, machine: dict) -> str:
    if record.get("status") == "compile_error" and "phases" not in record:
        return f"{record['program']}: compile error: {record.get('message')}"
    penalties = machine["penalties"]
    l1i, l1d, llc = machine["l1i"], machine["l1d"], machine["llc"]
    lines = []
    w = lines.append
    title = f" CPython baseline: {record['program']} "
    w("=" * 4 + title + "=" * max(4, 78 - len(title)))
    w(
        f"  machine   {machine['name']}  "
        f"L1I {l1i['size_bytes'] // 1024}KB/{l1i['associativity']}-way  "
        f"L1D {l1d['size_bytes'] // 1024}KB/{l1d['associativity']}-way  "
        f"LLC {llc['size_bytes'] // 1024}KB/{llc['associativity']}-way"
    )
    w(
        f"  model     {machine['model']}: 1 cycle/instr + "
        f"P_L1I={penalties['l1i']} P_L1D={penalties['l1d']} "
        f"P_LLC={penalties['llc']} P_br={penalties['branch']}"
    )
    w(
        f"  clock     {machine['frequency_mhz']:g} MHz "
        "(simulated time; cycles do not depend on it)"
    )
    dispatch = record["dispatch"]
    w(
        f"  dispatch  {dispatch['sites']} jump-table sites in {dispatch['function']} "
        f"({dispatch['method']})"
    )
    w(f"  status    {record['status']}")
    header = (
        f"  {'phase':<16}{'cycles':>14}{'instrs':>14}"
        f"{'L1I hit':>10}{'L1D hit':>10}{'LLC hit':>10}{'@ clock':>12}"
    )
    w("")
    w(header)
    phases = record["phases"]
    for name in ("compile_cold", "compile_warm", "interpret", "run", "run_cold", "run_warm"):
        if name in phases:
            w(_phase_line(name, phases[name]))
    breakdown = record["run_cold_breakdown"]
    exec_ir = phases["run_cold"]["events"]["Ir"] or 1
    w("")
    w("  run_cold split (dispatch edge / inline opcode bodies / C helpers)")
    for name in ("dispatch", "inline_opcodes", "c_helpers"):
        part = breakdown[name]
        share = 100.0 * part["events"]["Ir"] / exec_ir
        w(f"    {name:<18}{_n(part['cycles']):>14} cycles   {share:5.1f}% of exec instructions")
    per_bc = record.get("cycles_per_bytecode")
    if per_bc:
        w(
            f"  bytecodes { _n(record['bytecodes_executed']) }   "
            f"cycles/bytecode  dispatch {per_bc['dispatch']:.1f}  "
            f"exec {per_bc['exec']:.1f}"
        )
    code = record.get("code") or {}
    if code:
        w(
            f"  code      {code['instructions']} instructions, "
            f"{code['code_units']} code units (CACHE included), "
            f"{code['code_objects']} code objects"
        )
    tops = record.get("top_functions", {}).get("run_cold") or []
    if tops:
        w("  hottest run_cold functions by retired instructions")
        for item in tops[:5]:
            w(f"    {_n(item['instructions']):>12}  {item['function']}")
    for note in record.get("notes") or []:
        w(f"  note      {note}")
    w(f"  sim       callgrind finished in {record['sim_seconds']:.1f}s host time")
    w("=" * 78)
    return "\n".join(lines)


def _geomean(values: list[float]) -> float | None:
    if not values or any(v <= 0 for v in values):
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def render_suite(records: list[dict], machine: dict) -> str:
    lines = []
    w = lines.append
    w("")
    w(f"Suite on {machine['name']}  ({len(records)} programs)")
    w(
        f"  {'program':<24}{'compile':>14}{'interpret':>14}{'run':>14}"
        f"{'exec':>14}{'L1D':>8}{'LLC':>8}{'disp%':>8}"
    )
    exec_cycles = []
    shares = []
    for record in records:
        if "phases" not in record:
            w(f"  {Path_name(record):<24}  {record.get('status')}: {record.get('message')}")
            continue
        phases = record["phases"]
        name = record["program"].rsplit("/", 1)[-1]
        exec_ir = phases["run_cold"]["events"]["Ir"] or 1
        share = 100.0 * phases["interpret"]["events"]["Ir"] / exec_ir
        l1d = phases["run_cold"]["caches"]["l1d"]["hit_rate"]
        llc = phases["run_cold"]["caches"]["llc"]["hit_rate"]
        w(
            f"  {name:<24}{_n(phases['compile_cold']['cycles']):>14}"
            f"{_n(phases['interpret']['cycles']):>14}"
            f"{_n(phases['run']['cycles']):>14}"
            f"{_n(phases['run_cold']['cycles']):>14}"
            f"{_pct(l1d):>8}{_pct(llc):>8}{share:7.1f}%"
        )
        exec_cycles.append(phases["run_cold"]["cycles"])
        shares.append(share)
    geo = _geomean(exec_cycles)
    geo_share = _geomean(shares) if shares else None
    w(
        f"  {'geomean':<24}{'':>14}{'':>14}{'':>14}"
        f"{_n(round(geo)) if geo else '-':>14}"
        f"{'':>8}{'':>8}{(f'{geo_share:.1f}%' if geo_share else '-'):>8}"
    )
    w("  compile is cold; interpret is the dispatch edge of the cold exec;")
    w("  run is the rest of that exec (inline opcodes and C helpers).")
    return "\n".join(lines)


def Path_name(record: dict) -> str:
    return str(record.get("program", "?")).rsplit("/", 1)[-1]
