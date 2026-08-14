"""Docker/API e2e smoke: POST managed_entry → INT 12 (needs Verilator + 3.14)."""

from __future__ import annotations

import os
import sys
import unittest

# Skip unless explicitly enabled (CI / docker make target).
RUN_E2E = os.environ.get("SIM_UI_E2E", "") == "1"


@unittest.skipUnless(RUN_E2E, "set SIM_UI_E2E=1 to run Verilator e2e")
class E2ESmokeTests(unittest.TestCase):
    def test_smoke_return_12(self) -> None:
        from sim_ui.server.runner import create_session, health_check

        health = health_check()
        self.assertTrue(health["python_3_14"], health)
        self.assertTrue(health["verilator"], health)

        src = "def managed_entry():\n    return 12\n\nmanaged_entry()\n"
        sess = create_session(src, entry="managed_entry", max_cycles=50000, background=False)
        self.assertEqual(sess.status, "ready", sess.error)
        assert sess.end is not None
        self.assertEqual(sess.end["status"], "PASS")
        self.assertEqual(sess.end["return_value"]["display"], "12")
        self.assertTrue(sess.end["expected_match"])
        self.assertGreater(len(sess.steps), 0)


if __name__ == "__main__":
    if not RUN_E2E:
        print("Skipping e2e (SIM_UI_E2E!=1)", file=sys.stderr)
    unittest.main()
