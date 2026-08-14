"""Unit tests for JSONL trace parsing (no Verilator)."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from sim_ui.server.trace_parse import parse_trace_jsonl


GOLDEN = """\
{"t":"meta","excore":true,"boot_en":1,"max_cycles":200000,"heap_init_ptr":1088,"prog_hex":"x.hex"}
{"t":"step","step":0,"cycle":10,"pc":0,"opcode":128,"oparg":0,"state":"S_WB","tos":32,"locals_base":0,"tos_base":32,"frame_depth":0,"mem_owner":0,"heap_ptr":1280,"cur_code":1088,"stack":[],"locals":["100000000000000000000000000000002a"],"rf":{"0":"100000000000000000000000000000002a"},"frames":[{"depth":0,"pc_return":null,"tos_base":32,"locals_base":0,"code_addr":1088,"current":true,"locals_raw":["100000000000000000000000000000002a"]}],"heap_roots":[]}
{"t":"event","step":0,"cycle":40,"kind":"trap_req","code":19,"pc":12,"opcode":67,"arg":1,"mem_owner":1,"entry_count":1,"entries":["100000000000000000000000000000002a"]}
{"t":"event","step":0,"cycle":80,"kind":"trap_res","code":0,"pc":12,"opcode":67,"arg":1,"mem_owner":0,"entry_count":0,"entries":[]}
{"t":"step","step":1,"cycle":81,"pc":13,"opcode":84,"oparg":0,"state":"S_WB","tos":33,"locals_base":0,"tos_base":32,"frame_depth":1,"mem_owner":0,"heap_ptr":1536,"cur_code":1088,"stack":["100000000000000000000000000000002a"],"locals":["100000000000000000000000000000002a"],"rf":{"0":"100000000000000000000000000000002a","32":"100000000000000000000000000000002a"},"frames":[{"depth":1,"pc_return":null,"tos_base":33,"locals_base":0,"code_addr":1088,"current":true,"locals_raw":["100000000000000000000000000000002a"]}],"heap_roots":[]}
{"t":"end","status":"PASS","cycles":100,"opcodes":2,"trap_req_count":1,"trap_code":0,"return_tag":1,"return_value":"0000000000000000000000000000002a","expected_match":true}
"""


class TraceParseTests(unittest.TestCase):
    def test_parse_golden_mailbox(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "trace.jsonl"
            path.write_text(GOLDEN, encoding="utf-8")
            parsed = parse_trace_jsonl(path)
        self.assertEqual(parsed["step_count"], 2)
        self.assertEqual(parsed["end"]["status"], "PASS")
        self.assertEqual(parsed["end"]["return_value"]["display"], "42")
        self.assertEqual(parsed["end"]["trap_req_count"], 1)
        self.assertEqual(len(parsed["events"]), 2)
        self.assertEqual(parsed["events"][0]["code_name"], "DICT_UPDATE")
        self.assertTrue(parsed["events"][0]["recoverable"])
        self.assertEqual(len(parsed["events"][0]["entries"]), 1)
        # Events attached to step 0
        self.assertEqual(len(parsed["steps"][0]["events"]), 2)
        self.assertEqual(parsed["steps"][1]["opcode"], "LOAD_FAST")
        self.assertIn("0", parsed["steps"][0]["rf"])
        self.assertTrue(parsed["steps"][0]["keypoint"] or parsed["steps"][0]["events"])

    def test_json_roundtrip_fields(self) -> None:
        # Ensure each golden line is valid JSON (fixture hygiene).
        for line in GOLDEN.strip().splitlines():
            json.loads(line)


if __name__ == "__main__":
    unittest.main()
