#!/usr/bin/env python3.14
"""Interactive PyCore session: power on the hart, then feed it Python files.

    $ make shell
    pycore> examples/hello.py
    pycore> set latency 30
    pycore> again

Each file is handed to PyCore as source text; the on-device ``compile()``
builds it and ``exec()`` runs it (see ``pycore_exec.py``). Every run starts
from a fresh reset of the simulated machine, so one program cannot leave
state behind for the next; the report's ``boot`` line is that reset cost.
"""

from __future__ import annotations

import cmd
import dataclasses
import glob
import os
import pathlib
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pycore_exec  # noqa: E402
from pycore_exec import ExecConfig  # noqa: E402

REPO_ROOT = pycore_exec.REPO_ROOT

_SETTINGS = {
    # name: (ExecConfig field, parser, description)
    "cache": ("cache_en", lambda v: int(v in ("1", "on", "true", "yes")), "L1/L2 caches on|off"),
    "latency": ("mem_latency", int, "RAM latency in cycles (CI default 4)"),
    "max-cycles": ("max_cycles", lambda v: int(v.replace("_", "").replace(",", "")),
                   "stop a run after this many cycles"),
    "mhz": ("pycore_mhz", float, "assumed PyCore clock for the wall-clock column"),
    "compare": ("host", lambda v: v in ("1", "on", "true", "yes"),
                "also run the file on CPython and compare on|off"),
    "progress": ("progress", lambda v: v in ("1", "on", "true", "yes"),
                 "live cycle counter while simulating on|off"),
}


class PyCoreShell(cmd.Cmd):
    intro = ""
    prompt = "pycore> "

    def __init__(self, cfg: ExecConfig) -> None:
        super().__init__()
        self.cfg = cfg
        self.last: pathlib.Path | None = None
        self.history_file = REPO_ROOT / "build" / ".pycore_shell_history"

    # -- lifecycle -----------------------------------------------------------

    def preloop(self) -> None:
        try:
            import readline  # noqa: PLC0415

            readline.set_completer_delims(" \t\n")
            if self.history_file.is_file():
                readline.read_history_file(self.history_file)
        except (ImportError, OSError):
            pass

    def postloop(self) -> None:
        try:
            import readline  # noqa: PLC0415

            self.history_file.parent.mkdir(parents=True, exist_ok=True)
            readline.set_history_length(500)
            readline.write_history_file(self.history_file)
        except (ImportError, OSError):
            pass

    def emptyline(self) -> bool:
        return False

    # -- commands ------------------------------------------------------------

    def default(self, line: str) -> bool:
        path = line.strip()
        if path.endswith(".py") or os.path.isfile(os.path.expanduser(path)):
            return self.do_run(path)
        print(f"unknown command: {line.split()[0]!r} (type 'help')")
        return False

    def do_run(self, arg: str) -> bool:
        """run FILE.py  -- compile FILE on PyCore, run it, compare with CPython.
        (A bare path works too: `pycore> demo.py`.)"""
        try:
            parts = shlex.split(arg)
        except ValueError as exc:
            print(f"run: {exc}")
            return False
        if not parts:
            print("usage: run FILE.py")
            return False
        for part in parts:
            path = pathlib.Path(os.path.expanduser(part))
            if not path.is_file():
                print(f"run: {part}: file not found")
                continue
            self.last = path
            try:
                pycore_exec.exec_file(path, self.cfg)
            except KeyboardInterrupt:
                print("\n(interrupted)")
                return False
        return False

    def do_again(self, _arg: str) -> bool:
        """again  -- re-run the last file (picks up edits and new settings)."""
        if self.last is None:
            print("nothing to re-run yet")
            return False
        return self.do_run(shlex.quote(str(self.last)))

    do_r = do_again

    def do_set(self, arg: str) -> bool:
        """set NAME VALUE  -- change a setting (see `show`)."""
        parts = arg.split()
        if len(parts) != 2 or parts[0] not in _SETTINGS:
            print("usage: set NAME VALUE, where NAME is one of: " + ", ".join(_SETTINGS))
            return False
        field, parse, _ = _SETTINGS[parts[0]]
        try:
            setattr(self.cfg, field, parse(parts[1].lower()))
        except ValueError:
            print(f"set: bad value {parts[1]!r} for {parts[0]}")
            return False
        self.do_show("")
        return False

    def do_show(self, _arg: str) -> bool:
        """show  -- current settings."""
        for name, (field, _parse, desc) in _SETTINGS.items():
            val = getattr(self.cfg, field)
            if isinstance(val, bool):
                val = "on" if val else "off"
            elif field == "cache_en":
                val = "on" if val else "off"
            elif isinstance(val, int):
                val = f"{val:,}"
            print(f"  {name:<11} {val!s:<14} {desc}")
        return False

    def do_ls(self, arg: str) -> bool:
        """ls [DIR]  -- list .py files."""
        base = pathlib.Path(os.path.expanduser(arg.strip() or "."))
        files = sorted(p for p in base.glob("*.py"))
        dirs = sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith("."))
        for d in dirs:
            print(f"  {d}/")
        for f in files:
            print(f"  {f}")
        return False

    def do_quit(self, _arg: str) -> bool:
        """quit  -- power off."""
        print("PyCore powered off.")
        return True

    do_exit = do_quit

    def do_EOF(self, _arg: str) -> bool:  # noqa: N802 - cmd.Cmd naming
        print()
        return self.do_quit("")

    # -- completion ----------------------------------------------------------

    def _complete_path(self, text: str) -> list[str]:
        expanded = os.path.expanduser(text)
        out = []
        for match in glob.glob(expanded + "*"):
            if os.path.isdir(match):
                out.append(match + "/")
            elif match.endswith(".py"):
                out.append(match)
        return out

    def completedefault(self, text, _line, _begidx, _endidx):
        return self._complete_path(text)

    complete_run = completedefault
    complete_ls = completedefault

    def completenames(self, text, *ignored):
        return super().completenames(text, *ignored) + self._complete_path(text)

    def complete_set(self, text, line, _begidx, _endidx):
        if len(line.split()) <= 2 and not line.endswith(" ") or line.strip() == "set":
            return [n for n in _SETTINGS if n.startswith(text)]
        return []


def power_on(cfg: ExecConfig) -> int:
    """Build (or reuse) the simulator, print the machine summary."""
    print("PyCore -- CPython 3.14 bytecode hart + RV32 excore (Verilator model)")
    print("Powering on: checking the two-core simulator build...", flush=True)
    try:
        pycore_exec.ensure_simulator(quiet=True)
    except RuntimeError as exc:
        print(f"power-on failed: {exc}")
        return 1
    # Build a probe image once for the free-memory figures in the banner.
    probe = pathlib.Path(cfg.build_dir)
    if not probe.is_absolute():
        probe = REPO_ROOT / probe
    try:
        meta = pycore_exec.build_device_image(
            pycore_exec.build_harness("", "<probe>"), probe / "probe"
        )
        limits = pycore_exec.hardware_limits(meta)
        print(
            f"Ready. Resident compiler loaded; {limits['code_ram_free_slots']:,} code-RAM "
            f"slots and {limits['heap_free_bytes']:,} B heap free for your program."
        )
    except (ValueError, RuntimeError) as exc:
        print(f"Ready (could not size memory: {exc}).")
    print(
        "Give me a Python file to compile and run on the hart, e.g.\n"
        "  pycore> pycore/programs/demo_exec.py\n"
        "Commands: run FILE | again | set NAME VALUE | show | ls [DIR] | help | quit"
    )
    return 0


def main(cfg: ExecConfig | None = None) -> int:
    cfg = cfg or ExecConfig()
    rc = power_on(cfg)
    if rc:
        return rc
    shell = PyCoreShell(dataclasses.replace(cfg))
    while True:
        try:
            shell.cmdloop()
            return 0
        except KeyboardInterrupt:
            print("^C")
            shell.intro = ""


if __name__ == "__main__":
    raise SystemExit(main())
