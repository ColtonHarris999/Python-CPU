"""Unit tests for keypoint filtering."""

from __future__ import annotations

import unittest

from sim_ui.server.trace_parse import filter_keypoints


class KeypointTests(unittest.TestCase):
    def test_keeps_first_last_and_keypoints(self) -> None:
        steps = [
            {"step": 0, "opcode": "RESUME", "keypoint": False, "events": []},
            {"step": 1, "opcode": "LOAD_FAST", "keypoint": False, "events": []},
            {"step": 2, "opcode": "CALL", "keypoint": True, "events": []},
            {"step": 3, "opcode": "LOAD_CONST", "keypoint": False, "events": []},
            {
                "step": 4,
                "opcode": "DICT_UPDATE",
                "keypoint": True,
                "events": [{"kind": "trap_req"}],
            },
            {"step": 5, "opcode": "RETURN_VALUE", "keypoint": True, "events": []},
        ]
        out = filter_keypoints(steps)
        ops = [s["opcode"] for s in out]
        self.assertEqual(ops[0], "RESUME")
        self.assertIn("CALL", ops)
        self.assertIn("DICT_UPDATE", ops)
        self.assertEqual(ops[-1], "RETURN_VALUE")
        self.assertNotIn("LOAD_FAST", ops)


if __name__ == "__main__":
    unittest.main()
