"""The research comparison oracle is MicroPython, with C/C++/MicroPython MCU columns."""

from __future__ import annotations

import json
import pathlib
import shutil
import tempfile
import unittest

import mcu_bench

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "all-tests.yml"


class McuBenchTest(unittest.TestCase):
    def test_peers_are_similar_mcus_in_three_languages(self) -> None:
        boards = mcu_bench.load_boards()
        self.assertEqual([b["id"] for b in boards], ["rp2040", "stm32f411", "nrf52840"])
        for board in boards:
            self.assertEqual(list(board["languages"]), ["c", "cpp", "micropython"])
            self.assertGreater(board["clock_mhz"], 0)
            self.assertLessEqual(board["sram_kb"], 512)
            self.assertGreaterEqual(board["sram_kb"], 128)

    def test_a_peer_file_fills_one_cell(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "pico.json"
            path.write_text(json.dumps({
                "board": "rp2040",
                "language": "c",
                "program": "nbody.py",
                "seconds": 1.5,
            }), encoding="utf-8")
            results = mcu_bench.load_peer_results(pathlib.Path(tmp))
            self.assertEqual(mcu_bench._peer_cell(results, "rp2040", "c", "nbody.py"), "1.500 s")
            self.assertEqual(mcu_bench._peer_cell(results, "rp2040", "cpp", "nbody.py"), "not measured")

    def test_render_names_micropython_as_the_oracle(self) -> None:
        text = mcu_bench.render({
            "recorded": "2026-10-15T00:00:00Z",
            "micropython": "micropython",
            "micropython_version": "3.4.0",
            "boards": mcu_bench.load_boards(),
            "peer_results": [],
            "programs": [{
                "program": "nqueens.py",
                "status": "PASS",
                "checksum": "92",
                "pycore_cycles": 176053066,
                "micropython_s": 0.03,
            }],
        })
        self.assertIn("compared with MicroPython, not with CPython", text)
        self.assertIn("not measured", text)
        self.assertIn("RP2040", text)
        self.assertIn("176,053,066", text)

    def test_all_tests_gate_includes_the_mcu_job(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("needs: [changes, docs, host-tools, rtl-modules, hardware, compiler-vs-cpython, caching, mcu-bench]", workflow)
        self.assertIn("needs.mcu-bench.result", workflow)

    def test_live_micropython_matches_the_locked_checksums(self) -> None:
        if shutil.which("micropython") is None:
            self.skipTest("micropython is not installed")
        report = mcu_bench.build_report("micropython")
        self.assertEqual([r["status"] for r in report["programs"]], ["PASS"] * len(report["programs"]))
        self.assertGreaterEqual(len(report["programs"]), 10)


if __name__ == "__main__":
    unittest.main()
