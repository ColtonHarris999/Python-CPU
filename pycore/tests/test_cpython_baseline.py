"""Cycle model, machine specs, Callgrind parser, and one simulated run.

The simulated run needs valgrind, gcc, and binutils. It is skipped when
those are missing so a host that only has the unit tests still passes.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(_TOOLS))

from cpython_baseline.callgrind import label_anonymous, parse_callgrind  # noqa: E402
from cpython_baseline.cycle_model import cycles  # noqa: E402
from cpython_baseline.dispatch import dispatch_sites  # noqa: E402
from cpython_baseline.machine import apply_overrides, load_machine  # noqa: E402

_DUMP = """\
# callgrind format
version: 1
creator: callgrind-test
positions: instr line
events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
summary: 13 3 1 1 1 0 0 1 0 2 1 1 0

desc: I1 cache: 8192 B, 64 B, 4-way associative
desc: D1 cache: 8192 B, 64 B, 4-way associative
desc: LL cache: 131072 B, 64 B, 8-way associative
desc: Trigger: Client Request: run_cold

ob=(1) /usr/local/lib/libpython3.14.so.1.0
fn=(1) _PyEval_EvalFrameDefault
0x1000 0 4 1 0 0 1 0 0 1 0 1 0 1 0
+4 0 2 1 0 1 0 0 0 0 0 1 1
cfn=(2) PyLong_Add
calls=1 0x2000 0
* 0 100 0 0 0 0 0 0 0 0 0 0 0 0
+4 0 4 1 1 0 0 0 0 0 0 0 0 0

fn=(2) PyLong_Add
0x2000 0 3 0 0 0 0 0 0 0 0 0 0 0
"""

# Two dispatch tails copied from CPython 3.14's computed-goto eval loop,
# plus a body instruction that must not be included.
_ASM = """\
00000000001ad640 <_PyEval_EvalFrameDefault>:
  1ad743:	49 8b 44 c5 50       	mov    0x50(%r13,%rax,8),%rax
  1ad748:	48 8b b5 98 fd ff ff 	mov    -0x268(%rbp),%rsi
  1ad74f:	48 83 c8 01          	or     $0x1,%rax
  1ad753:	48 89 43 f8          	mov    %rax,-0x8(%rbx)
  1ad757:	41 0f b7 07          	movzwl (%r15),%eax
  1ad75b:	0f b6 cc             	movzbl %ah,%ecx
  1ad75e:	0f b6 c0             	movzbl %al,%eax
  1ad761:	41 89 ce             	mov    %ecx,%r14d
  1ad764:	ff 24 c6             	jmp    *(%rsi,%rax,8)
  1ad8b0:	48 83 c3 08          	add    $0x8,%rbx
  1ad8b4:	41 0f b7 07          	movzwl (%r15),%eax
  1ad8b8:	0f b6 cc             	movzbl %ah,%ecx
  1ad8bc:	0f b6 c0             	movzbl %al,%eax
  1ad8bf:	41 89 ce             	mov    %ecx,%r14d
  1ad8c2:	48 8b 8d 98 fd ff ff 	mov    -0x268(%rbp),%rcx
  1ad8cc:	48 8b 14 c1          	mov    (%rcx,%rax,8),%rdx
  1ad8d0:	ff e2                	jmp    *%rdx
"""


class CycleModelTest(unittest.TestCase):
    def test_miss_penalty_is_not_charged_twice(self):
        penalties = type("P", (), {"l1i": 7, "l1d": 7, "llc": 4, "branch": 16})()
        events = {
            "Ir": 1000,
            "Dr": 0,
            "Dw": 0,
            "I1mr": 10,
            "D1mr": 5,
            "D1mw": 1,
            "ILmr": 2,
            "DLmr": 1,
            "DLmw": 0,
            "Bc": 0,
            "Bcm": 3,
            "Bi": 0,
            "Bim": 1,
        }
        # 1000 + 10*7 + 2*4 + 6*7 + 1*4 + 4*16
        self.assertEqual(cycles(events, penalties), 1188)


class MachineTest(unittest.TestCase):
    def test_pycore_penalties_match_the_hart(self):
        machine = load_machine("pycore")
        self.assertEqual(machine.l1i.size_bytes, 8192)
        self.assertEqual(machine.llc.size_bytes, 128 * 1024)
        self.assertEqual(machine.penalties.l1i, 7)
        self.assertEqual(machine.penalties.l1d, 7)
        self.assertEqual(machine.penalties.llc, 4)
        self.assertEqual(machine.penalties.branch, 16)
        self.assertEqual(machine.frequency_mhz, 100)

    def test_romer_penalties(self):
        machine = load_machine("romer")
        self.assertEqual(machine.l1i.associativity, 1)
        self.assertEqual(machine.penalties.l1i, 6)
        self.assertEqual(machine.penalties.llc, 24)
        self.assertEqual(machine.penalties.branch, 4)

    def test_set_count_must_be_a_power_of_two(self):
        machine = load_machine("pycore")
        with self.assertRaises(ValueError):
            apply_overrides(machine, {"l1i_assoc": 3, "l1i_bytes": None, "l1d_bytes": None,
                                      "llc_bytes": None, "l1d_assoc": None, "llc_assoc": None,
                                      "line_bytes": None, "l1i_hit": None, "l1d_hit": None,
                                      "llc_hit": None, "mem_latency": None, "branch_penalty": None,
                                      "mhz": None})

    def test_override_rebuilds_penalties(self):
        machine = load_machine("pycore")
        keys = {name: None for name in (
            "l1i_bytes", "l1d_bytes", "llc_bytes", "l1i_assoc", "l1d_assoc", "llc_assoc",
            "line_bytes", "l1i_hit", "l1d_hit", "llc_hit", "mem_latency", "branch_penalty", "mhz",
        )}
        keys["llc_hit"] = 20
        keys["mem_latency"] = 50
        adjusted = apply_overrides(machine, keys)
        self.assertEqual(adjusted.penalties.l1i, 19)
        self.assertEqual(adjusted.penalties.llc, 30)


class CallgrindParserTest(unittest.TestCase):
    def test_self_cost_skips_callee_and_keeps_dispatch_addresses(self):
        profile = parse_callgrind(_DUMP, keep_addrs={0x1000, 0x1004})
        self.assertEqual(profile.trigger, "run_cold")
        self.assertEqual(profile.summary["Ir"], 13)
        self.assertEqual(profile.functions["_PyEval_EvalFrameDefault"]["Ir"], 10)
        self.assertEqual(profile.functions["PyLong_Add"]["Ir"], 3)
        self.assertEqual(profile.addrs[0x1000]["Ir"], 4)
        self.assertEqual(profile.addrs[0x1004]["Ir"], 2)
        self.assertEqual(profile.caches["LL"], (131072, 64, 8))
        self.assertEqual(profile.fn_sites["_PyEval_EvalFrameDefault"], (
            "/usr/local/lib/libpython3.14.so.1.0",
            0x1000,
        ))

    def test_anonymous_function_is_labeled_by_object_and_address(self):
        text = """\
positions: instr
events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
summary: 4 0 0 0 0 0 0 0 0 0 0 0 0
desc: Trigger: Client Request: run_cold

ob=(1) /no/such/libpython.so
fn=(9)
0x3000 4
"""
        profile = parse_callgrind(text)
        label_anonymous(profile)
        self.assertEqual(profile.functions["libpython.so+0x3000"]["Ir"], 4)
        self.assertNotIn("9", profile.functions)

    @unittest.skipUnless(shutil.which("readelf"), "readelf is required")
    def test_address_inside_an_exported_symbol_uses_that_name(self):
        from cpython_baseline.dispatch import eval_frame_symbol, find_libpython

        lib = find_libpython()
        addr, _size = eval_frame_symbol(lib)
        text = f"""\
positions: instr
events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
summary: 4 0 0 0 0 0 0 0 0 0 0 0 0
desc: Trigger: Client Request: run_cold

ob=(1) {lib}
fn=(7)
0x{addr:x} 4
"""
        profile = parse_callgrind(text)
        label_anonymous(profile)
        self.assertEqual(profile.functions["_PyEval_EvalFrameDefault"]["Ir"], 4)


class DispatchTest(unittest.TestCase):
    def test_jump_table_edge_excludes_the_opcode_body(self):
        addresses, sites = dispatch_sites(_ASM)
        self.assertEqual(sites, 2)
        self.assertIn(0x1AD757, addresses)  # movzwl fetch
        self.assertIn(0x1AD764, addresses)  # jmp *table
        self.assertIn(0x1AD8D0, addresses)  # jmp *%reg form
        self.assertIn(0x1AD8B4, addresses)  # fetch of the split form
        self.assertNotIn(0x1AD753, addresses)  # store that belongs to the body
        self.assertNotIn(0x1AD8B0, addresses)  # add before the fetch


@unittest.skipUnless(shutil.which("valgrind") and shutil.which("objdump") and shutil.which("gcc"),
                     "valgrind, gcc, and objdump are required")
class SimulatedRunTest(unittest.TestCase):
    def test_dispatch_loop_on_the_pycore_machine(self):
        from cpython_baseline.runner import measure

        program = _TOOLS / "cpython_baseline" / "benchmarks" / "dispatch_loop.py"
        machine = load_machine("pycore")
        with tempfile.TemporaryDirectory() as tmp:
            record = measure(program, machine, Path(tmp))
        self.assertEqual(record["status"], "ok")
        self.assertEqual(record["stdout"].strip(), "7998000")
        phases = record["phases"]
        self.assertGreater(phases["compile_cold"]["cycles"], phases["compile_warm"]["cycles"])
        self.assertGreater(phases["interpret"]["cycles"], 0)
        self.assertGreater(phases["run"]["cycles"], 0)
        share = phases["interpret"]["events"]["Ir"] / phases["run_cold"]["events"]["Ir"]
        # The dispatch edge is a few percent of a tight loop, not the whole
        # eval function and not nothing. Zhang, Xu, and Xu measured ~8.5%.
        self.assertGreater(share, 0.01)
        self.assertLess(share, 0.20)
        exec_ir = phases["run_cold"]["events"]["Ir"]
        split_ir = (
            record["run_cold_breakdown"]["dispatch"]["events"]["Ir"]
            + record["run_cold_breakdown"]["inline_opcodes"]["events"]["Ir"]
            + record["run_cold_breakdown"]["c_helpers"]["events"]["Ir"]
        )
        self.assertEqual(split_ir, exec_ir)
        self.assertEqual(
            phases["interpret"]["events"]["Ir"] + phases["run"]["events"]["Ir"],
            exec_ir,
        )
        self.assertGreater(record["dispatch"]["sites"], 50)
        self.assertEqual(record["dispatch"]["method"], "jump_table_edge")
        self.assertLess(record["instrumentation_arm_instructions"], 100_000)
        l1d = phases["run_cold"]["caches"]["l1d"]["hit_rate"]
        self.assertGreater(l1d, 0.5)
        self.assertLessEqual(l1d, 1.0)
        self.assertGreater(record["bytecodes_executed"], 1000)
        self.assertGreater(record["cycles_per_bytecode"]["dispatch"], 0)
        for item in record["top_functions"]["run_cold"]:
            self.assertFalse(item["function"].isdigit(), item["function"])


if __name__ == "__main__":
    unittest.main()
