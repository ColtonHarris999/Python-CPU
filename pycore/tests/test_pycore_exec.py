"""Host-side tests for ``pycore_cli.py exec`` / ``shell`` (no Verilator).

The simulator is replaced by a small script that speaks the testbench's
PHASE_MARK / console protocol, so the whole exec pipeline -- harness build,
live console tail, mark parsing, CPython reference, report -- runs in the
Python unit-test job.
"""

from __future__ import annotations

import io
import json
import pathlib
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT / "pycore" / "tools"))

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("pycore_exec tests require Python 3.14")

import host_reference  # noqa: E402
import pycore_cli  # noqa: E402
import pycore_exec  # noqa: E402

DEMO = _REPO_ROOT / "pycore" / "programs" / "demo_exec.py"


def _run_harness_on_host(source: str) -> str:
    """Execute the harness on CPython with stand-ins for the device builtins.

    Returns everything the harness wrote to the console, marks included.
    """
    out: list[str] = []
    heap = [1000]
    code_slots = [50000]

    def bi_print(v):
        out.append(v if isinstance(v, str) else str(v))

    def bi_code_kind(v):
        if isinstance(v, str):
            return 7 if len(v.encode()) <= 15 else 8
        if isinstance(v, bool):
            return 4
        if isinstance(v, int):
            return 1
        return 0 if v is None else 9

    def heap_mark():
        heap[0] += 64
        return heap[0]

    def code_mark():
        code_slots[0] += 3
        return code_slots[0]

    ns = {
        "__name__": "__pycore_harness__",
        "_bi_print": bi_print,
        "_bi_code_kind": bi_code_kind,
        "_bi_heap_mark": heap_mark,
        "_bi_code_mark": code_mark,
    }
    def device_print(*args, sep=" ", end="\n"):
        out.append(sep.join(str(a) for a in args) + end)

    # The compiled program's print() writes to the console like _bi_print.
    import builtins  # noqa: PLC0415

    with mock.patch.object(builtins, "print", device_print):
        exec(compile(pycore_exec.build_harness(source, "t.py"), "<harness>", "exec"), ns)
    return "".join(out)


class HarnessTest(unittest.TestCase):
    def test_harness_marks_and_stats(self) -> None:
        text = _run_harness_on_host('print("hi", 3)\n')
        self.assertTrue(text.startswith("\x01\x02\x03hi 3\n\x04"), repr(text))
        self.assertIn("\x0estats:0:", text)
        self.assertTrue(text.endswith("\x0f"))

    def test_harness_reports_runtime_exception(self) -> None:
        text = _run_harness_on_host('print(1)\nraise ValueError("a long message here")\n')
        self.assertIn("\x0eexc:run:ValueError:a long message here\x0f", text)
        self.assertIn("\x0estats:1:", text)

    def test_harness_reports_compile_error(self) -> None:
        text = _run_harness_on_host("def (:\n")
        self.assertIn("\x0eexc:compile:SyntaxError:", text)
        self.assertIn("\x0estats:2:", text)
        self.assertNotIn("\x04\x0eexc:run", text)

    def test_harness_builds_a_boot_image(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            meta = pycore_exec.build_device_image(
                pycore_exec.build_harness(DEMO.read_text(encoding="utf-8"), "demo.py"),
                pathlib.Path(tmp),
            )
            for key in ("HEAP_INIT_PTR", "CODE_RAM_INIT_SLOT"):
                self.assertIn(key, meta)
            self.assertEqual(meta["EXPECTED_TAG"], "1")
            self.assertEqual(meta["EXPECTED_VALUE"], "0")
            limits = pycore_exec.hardware_limits(meta)
            self.assertGreater(limits["code_ram_free_slots"], 0)
            self.assertGreater(limits["heap_free_bytes"], 0)

    def test_every_harness_exception_is_seeded(self) -> None:
        from image_from_source import WAVE_A_EXCEPTION_TYPES  # noqa: PLC0415

        seeded = {name for name, _parent in WAVE_A_EXCEPTION_TYPES}
        self.assertLessEqual(set(pycore_exec.EXCEPTION_ORDER), seeded)


class ConsoleTailTest(unittest.TestCase):
    def test_meta_is_stripped_across_chunk_boundaries(self) -> None:
        tail = pycore_exec._StdoutTail(pathlib.Path("/nonexistent"), None)
        for chunk in (b"hel", b"lo\n\x0eexc:ru", b"n:Val", b"ueError:x\x0f", b"\xc3", b"\xa9\n"):
            tail._feed(chunk)
        tail._feed(b"", final=True)
        self.assertEqual("".join(tail.program_out), "hello\né\n")
        self.assertEqual(tail.meta, ["exc:run:ValueError:x"])

    def test_latin1_console_bytes_decode(self) -> None:
        tail = pycore_exec._StdoutTail(pathlib.Path("/nonexistent"), None)
        tail._feed(b"h\xe9llo \xc3")
        tail._feed(b"\xa9\n", final=True)
        self.assertEqual("".join(tail.program_out), "h\u00e9llo \u00e9\n")


class ReportTest(unittest.TestCase):
    def _dev(self, **kw) -> pycore_exec.DeviceResult:
        marks = {
            1: dict(cycle=3000, instr=30, excore_traps=1, excore_wait=1000,
                    l1i_hit=0, l1i_miss=6, l1d_hit=300, l1d_miss=30),
            2: dict(cycle=4000, instr=34, excore_traps=2, excore_wait=1900,
                    l1i_hit=0, l1i_miss=7, l1d_hit=400, l1d_miss=50),
            3: dict(cycle=105000, instr=4034, excore_traps=3, excore_wait=2800,
                    l1i_hit=900, l1i_miss=100, l1d_hit=9000, l1d_miss=1000),
            4: dict(cycle=116000, instr=4134, excore_traps=5, excore_wait=5000,
                    l1i_hit=1000, l1i_miss=110, l1d_hit=9500, l1d_miss=1100),
        }
        base = dict(outcome="ok", marks=marks, total_cycles=120000,
                    harness_status=0, heap_compile=5000, code_slots=12,
                    heap_run=100, stdout="hi\n", wall_s=1.0, log_path="sim.log")
        base.update(kw)
        return pycore_exec.DeviceResult(**base)

    def test_phases_subtract_marker_overhead(self) -> None:
        ph = pycore_exec.device_phases(self._dev())
        self.assertEqual(ph["boot_cycles"], 3000)
        self.assertEqual(ph["marker_overhead_cycles"], 1000)
        self.assertEqual(ph["compile"]["cycle"], 101000 - 1000)
        self.assertEqual(ph["compile"]["instr"], 4000 - 4)
        self.assertEqual(ph["run"]["cycle"], 11000 - 1000)
        self.assertEqual(ph["run"]["excore_traps"], 2)

    def test_trap_is_charged_to_its_phase(self) -> None:
        dev = self._dev(outcome="trap", trap_code=1, trap_name="TYPE",
                        trap_cycle=110000, total_cycles=110000, trap_phase="run")
        del dev.marks[4]
        ph = pycore_exec.device_phases(dev)
        self.assertEqual(ph["run"], {"cycle": 5000, "partial": True})
        verdict, detail = pycore_exec.evaluate(dev, {"status": "ok", "stdout": "hi\n"})
        self.assertEqual(verdict, "TRAP")
        self.assertIn("TYPE", detail)
        self.assertIn("print()", detail)

    def test_verdicts(self) -> None:
        ok = {"status": "ok", "stdout": "hi\n"}
        self.assertEqual(pycore_exec.evaluate(self._dev(), ok)[0], "PASS")
        self.assertEqual(
            pycore_exec.evaluate(self._dev(stdout="ho\n"), ok)[0], "MISMATCH")
        self.assertEqual(pycore_exec.evaluate(self._dev(), None)[0], "RAN")
        rejected = self._dev(outcome="compile_error", harness_status=2,
                             exception={"phase": "compile", "name": "SyntaxError",
                                        "message": "unsupported statement 'class'"})
        verdict, detail = pycore_exec.evaluate(rejected, ok)
        self.assertEqual(verdict, "UNSUPPORTED")
        self.assertIn("class", detail)
        raised = self._dev(outcome="exception", harness_status=1,
                           exception={"phase": "run", "name": "ValueError", "message": "x"})
        host_raised = {"status": "runtime_error", "stdout": "hi\n", "exception": "ValueError"}
        self.assertEqual(pycore_exec.evaluate(raised, host_raised)[0], "PASS")
        self.assertEqual(pycore_exec.evaluate(raised, ok)[0], "MISMATCH")

    def test_render_report_mentions_both_sides(self) -> None:
        host = host_reference.run_reference('print("hi")\n', "t.py", compile_reps=2)
        dev = self._dev()
        text, report = pycore_exec.render_report(
            source=pathlib.Path("t.py"), prepared='print("hi")\n', dev=dev, host=host,
            limits={"code_ram_free_slots": 100, "heap_free_bytes": 1000},
            cfg={"cache_en": 1, "mem_latency": 4, "max_cycles": 10, "pycore_mhz": 100.0},
            notes=[],
        )
        self.assertIn("PASS", text)
        self.assertIn("compile", text)
        self.assertIn("PyCore/CPython", text)
        self.assertEqual(report["verdict"], "PASS")
        json.dumps(report)  # the report must stay serializable


class HostReferenceTest(unittest.TestCase):
    def test_captures_output_and_counts_bytecodes(self) -> None:
        res = host_reference.run_reference(
            "t = 0\nfor i in range(10):\n    t += i\nprint(t)\n", "t.py", compile_reps=2
        )
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["stdout"], "45\n")
        self.assertGreater(res["bytecodes_executed"], 20)
        self.assertGreater(res["compile"]["first"]["ns"], 0)
        self.assertGreater(res["code"]["instructions"], 0)

    def test_runtime_error_and_syntax_error(self) -> None:
        res = host_reference.run_reference('print(1)\nraise KeyError("k")\n', "t.py", compile_reps=1)
        self.assertEqual(res["status"], "runtime_error")
        self.assertEqual(res["exception"], "KeyError")
        self.assertEqual(res["stdout"], "1\n")
        res = host_reference.run_reference("def (:\n", "t.py", compile_reps=1)
        self.assertEqual(res["status"], "compile_error")


_FAKE_SIM = r'''#!{python}
"""Stand-in for Vtb_container: replays the PHASE_MARK / console protocol."""
import sys
args = dict(a[1:].split("=", 1) for a in sys.argv[1:] if a.startswith("+") and "=" in a)
out = open(args["STDOUT_PATH"], "w")
def mark(i, cyc, instr):
    print(f"PHASE_MARK id={{i}} cycle={{cyc}} instr={{instr}} excore_traps=0 excore_wait=0 "
          f"l1i_hit=10 l1i_miss=1 l1d_hit=20 l1d_miss=2", flush=True)
mark(1, 3000, 30)
mark(2, 4000, 34)
print("HEARTBEAT cycle=50000 instr=900", flush=True)
mark(3, 104000, 3034)
out.write("hi 3\n"); out.flush()
mark(4, 110000, 3100)
out.write("\x0estats:0:4096:9:128\x0f"); out.close()
print("PASS: prog — tag=1 value=0x0 cycles=120000")
print("PERF instr=3200 excore_traps=0 excore_wait=0")
'''


class ExecPipelineTest(unittest.TestCase):
    def test_exec_file_with_fake_simulator(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            sim = tmp / "Vtb_container"
            sim.write_text(_FAKE_SIM.format(python=sys.executable), encoding="utf-8")
            sim.chmod(sim.stat().st_mode | stat.S_IEXEC)
            prog = tmp / "prog.py"
            prog.write_text('print("hi", 3)\n', encoding="utf-8")
            cfg = pycore_exec.ExecConfig(build_dir=str(tmp / "work"), progress=False)
            buf = io.StringIO()
            with mock.patch.object(pycore_exec, "ensure_simulator", return_value=sim):
                rc = pycore_exec.exec_file(prog, cfg, out=buf)
            text = buf.getvalue()
            self.assertEqual(rc, 0, text)
            self.assertIn("hi 3\n", text)
            self.assertIn("PASS -- output matches CPython", text)
            self.assertIn("99,000", text)  # compile: 104000 - 4000 - 1000 mark overhead
            report = json.loads((tmp / "work" / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["verdict"], "PASS")
            self.assertEqual(report["device"]["phases"]["compile"]["cycle"], 99000)
            self.assertEqual(report["device"]["phases"]["run"]["cycle"], 5000)
            self.assertEqual(report["device"]["code_slots"], 9)
            self.assertEqual(report["host"]["stdout"], "hi 3\n")


class CliTest(unittest.TestCase):
    def test_help_lists_exec_and_shell(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            pycore_cli.main(["help"])
        text = buf.getvalue()
        self.assertIn("pycore_cli.py exec", text)
        self.assertIn("make shell", text)

    def test_exec_parser_options(self) -> None:
        args = pycore_cli.build_parser().parse_args(
            ["exec", "a.py", "b.py", "--mem-latency", "30", "--no-host"]
        )
        self.assertEqual(args.sources, ["a.py", "b.py"])
        cfg = pycore_cli._exec_config(args)
        self.assertEqual(cfg.mem_latency, 30)
        self.assertFalse(cfg.host)

    def test_demo_matches_cpython_on_host(self) -> None:
        res = host_reference.run_reference(DEMO.read_text(encoding="utf-8"), "demo.py",
                                           compile_reps=1)
        self.assertEqual(res["status"], "ok")
        self.assertIn("fib(30): 832040", res["stdout"])
        # print() on PyCore takes strings up to 15 bytes: keep the demo inside it.
        for line in DEMO.read_text(encoding="utf-8").splitlines():
            if "print(" in line:
                for piece in line.split('"')[1::2]:
                    self.assertLessEqual(len(piece.encode()), 15, line)


class ShellTest(unittest.TestCase):
    def test_settings_and_dispatch(self) -> None:
        import pycore_shell  # noqa: PLC0415

        shell = pycore_shell.PyCoreShell(pycore_exec.ExecConfig())
        with redirect_stdout(io.StringIO()):
            shell.onecmd("set latency 30")
            shell.onecmd("set cache off")
            shell.onecmd("set max-cycles 1_000")
        self.assertEqual(shell.cfg.mem_latency, 30)
        self.assertEqual(shell.cfg.cache_en, 0)
        self.assertEqual(shell.cfg.max_cycles, 1000)
        with mock.patch.object(pycore_exec, "exec_file", return_value=0) as ex:
            with redirect_stdout(io.StringIO()):
                shell.onecmd(str(DEMO))
                shell.onecmd("again")
        self.assertEqual(ex.call_count, 2)
        self.assertEqual(ex.call_args[0][0], DEMO)
        with redirect_stdout(io.StringIO()):
            self.assertTrue(shell.onecmd("quit"))


if __name__ == "__main__":
    unittest.main()
