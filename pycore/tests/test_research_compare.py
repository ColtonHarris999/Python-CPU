"""Pairing of CPython baseline records with PyCore exec reports.

No simulator and no Callgrind: the runners are covered by executing the
research set, and this checks that every baseline column lands in the
comparison with the right ratio.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(_TOOLS))

from research_compare import (  # noqa: E402
    build_payload,
    compare_program,
    machine_chart_data,
    render_chart_svg,
    render_machines_markdown,
    render_markdown,
)


def _phase(cycles: int, ir: int, l1i_hit: float, l1d_hit: float, llc_hit: float, mpki: float) -> dict:
    def level(hit_rate: float) -> dict:
        return {"hit_rate": hit_rate, "mpki": mpki, "accesses": ir, "misses": 1, "hits": ir - 1}

    return {
        "cycles": cycles,
        "cpi": cycles / ir,
        "simulated_ns": cycles * 10.0,  # 100 MHz
        "events": {"Ir": ir},
        "caches": {
            "l1i": level(l1i_hit),
            "l1d": level(l1d_hit),
            "llc": level(llc_hit),
            "branch": {"mpki": mpki},
        },
    }


def _cpython() -> dict:
    cold = _phase(1000, 100, 0.90, 0.80, 0.70, 12.0)
    warm = _phase(1100, 100, 0.91, 0.81, 0.71, 11.0)
    interpret = _phase(200, 20, 0.5, 0.5, 0.5, 1.0)
    run = _phase(800, 80, 0.5, 0.5, 0.5, 1.0)
    return {
        "program": "fannkuch.py",
        "status": "ok",
        "stdout": "16\n",
        "bytecodes_executed": 50,
        "cycles_per_bytecode": {"dispatch": 4.0, "exec": 20.0},
        "code": {"instructions": 40, "code_units": 80},
        "phases": {
            "compile_cold": cold,
            "compile_warm": warm,
            "interpret": interpret,
            "run": run,
            "run_cold": cold,
            "run_warm": warm,
        },
        "run_cold_breakdown": {
            "dispatch": interpret,
            "inline_opcodes": run,
            "c_helpers": _phase(100, 10, 1.0, 1.0, 1.0, 0.0),
        },
        "top_functions": {"run_cold": [{"function": "PyLong_Add", "instructions": 10}]},
        "notes": [],
        "_machine_mhz": 100.0,
    }


def _pycore() -> dict:
    def phase(cycle: int, instr: int) -> dict:
        return {
            "cycle": cycle,
            "instr": instr,
            "excore_traps": 2,
            "excore_wait": 100,
            "l1i_hit": 90,
            "l1i_miss": 10,
            "l1d_hit": 70,
            "l1d_miss": 30,
        }

    return {
        "verdict": "PASS",
        "device": {
            "stdout": "16\n",
            "code_slots": 30,
            "phases": {"compile": phase(500, 25), "run": phase(250, 40)},
        },
    }


class CompareProgramTest(unittest.TestCase):
    def test_fair_exec_ratio_and_shared_bytecode_denominator(self):
        rows = {(r.group, r.name): r for r in compare_program(_cpython(), _pycore(), pycore_mhz=1000.0)}
        exec_cycles = rows[("exec (cold, interpret + run)", "cycles")]
        self.assertEqual(exec_cycles.cpython, 1000)
        self.assertEqual(exec_cycles.pycore, 250)
        self.assertEqual(exec_cycles.compare, "0.25x")
        per_bc = rows[("bytecode", "exec cycles per CPython bytecode")]
        self.assertEqual(per_bc.cpython, 20.0)
        self.assertEqual(per_bc.pycore, 5.0)
        self.assertEqual(per_bc.compare, "0.25x")

    def test_dispatch_edge_is_recorded_without_a_hart_number(self):
        rows = {(r.group, r.name): r for r in compare_program(_cpython(), _pycore(), pycore_mhz=1000.0)}
        interpret = rows[("interpret (dispatch edge)", "cycles")]
        self.assertEqual(interpret.cpython, 200)
        self.assertIsNone(interpret.pycore)
        self.assertIn("inside each bytecode", interpret.note)
        self.assertIsNone(rows[("exec (warm)", "cycles")].pycore)
        self.assertEqual(rows[("compile (warm)", "cycles")].cpython, 1100)

    def test_l1_hit_rate_uses_phase_counters(self):
        rows = {(r.group, r.name): r for r in compare_program(_cpython(), _pycore(), pycore_mhz=1000.0)}
        l1d = rows[("exec (cold, interpret + run)", "L1D hit rate")]
        self.assertEqual(l1d.cpython, "80.0%")
        self.assertEqual(l1d.pycore, "70.0%")
        self.assertEqual(l1d.compare, "-10.0 pp")

    def test_markdown_suite_has_one_row_and_the_geomean(self):
        payload = build_payload(
            {"machine": {"name": "pycore", "frequency_mhz": 100.0}, "programs": [_cpython()]},
            {"fannkuch.py": _pycore()},
            pycore_mhz=1000.0,
            pycore_config={"mem_latency": 4},
        )
        text = render_markdown(payload)
        self.assertIn("exec ×", text)
        self.assertIn("fannkuch.py", text)
        self.assertIn("0.25x", text)
        self.assertIn("geomean", text)
        header = next(line for line in text.splitlines() if line.startswith("| program |"))
        data = next(line for line in text.splitlines() if line.startswith("| fannkuch.py |"))
        self.assertEqual(header.count("|"), data.count("|"))
        self.assertEqual(payload["suite"][0]["exec_ratio"], 0.25)


class MachineChartTest(unittest.TestCase):
    def test_chart_scales_time_by_each_machines_clock(self):
        record = _cpython()
        record["status"] = "ok"
        pycore = {"fannkuch.py": _pycore()}
        cpython_machine = {
            "machine": {"name": "romer", "frequency_mhz": 100.0},
            "programs": [record],
        }
        data = machine_chart_data(pycore, {"romer": cpython_machine}, pycore_mhz=1000.0)
        hart = data["programs"][0]["series"]["pycore-hart"]
        romer = data["programs"][0]["series"]["romer"]
        self.assertEqual(hart["cycles"], 250)
        self.assertAlmostEqual(hart["seconds"], 250 / 1e9)
        self.assertEqual(romer["cycles"], 1000)
        self.assertAlmostEqual(romer["seconds"], 1000 / 1e8)
        svg = render_chart_svg(data)
        self.assertIn("<svg", svg)
        self.assertIn("PyCore hart", svg)
        self.assertIn("Romer", svg)
        self.assertIn("10 us", svg)
        self.assertNotIn("10.00", svg)
        text = render_machines_markdown(data)
        self.assertIn("research_machines.svg", text)
        self.assertIn("fannkuch.py", text)
        self.assertEqual(data["geomean"]["pycore-hart"]["programs"], 1)


if __name__ == "__main__":
    unittest.main()
