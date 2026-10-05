#!/usr/bin/env python3.14
"""Run the hardware tests in ``pycore/programs/hw_tests.toml``.

Each test is one program run on the simulated hart. Tests are grouped into
areas by what they check (``alu``, ``strings``, ``exceptions``, ...). The
runner builds each test's image once and runs it under one or more memory
configurations, so a sweep does not rebuild identical images.

Usage::

    python3.14 pycore/tools/hw_tests.py --area alu            # one area
    python3.14 pycore/tools/hw_tests.py --area all --jobs 4   # every area
    python3.14 pycore/tools/hw_tests.py --caching             # memory-system gate
    python3.14 pycore/tools/hw_tests.py 'str-*' --config 0,30 # by name, custom config
    python3.14 pycore/tools/hw_tests.py --list --area calls
    python3.14 pycore/tools/hw_tests.py --gate G4             # one GC gate's runs

``make test-<area>``, ``make test-hw`` and ``make test-caching`` wrap it.

The caching gate
----------------
Every area job runs the default configuration (``CACHE_EN=1``,
``MEM_LATENCY=4``). The gate adds the others, and a result that differs from
the host golden under any of them fails:

* cache off at latency 1, 4 and 30 -- the memory master must be correct at
  any latency. This does not depend on working-set size, so the
  ``compiler`` area only contributes its entries marked ``caching = true``
  (a compile fixture is 10-50x the cycles of anything else when uncached).
* cache on at latency 30 -- everything, compiler included. Large working
  sets are what drive L1/L2 evictions and writebacks to RAM.

GC gates
--------
The ``[gate.*]`` tables of the manifest are not areas: each names a set of
tests and the plusargs one GC acceptance gate adds to them (see the comment
above them in hw_tests.toml). ``--gate G4`` runs that set by hand;
``tools/gc_gates.py`` runs the same sets through :func:`run_tests` and
checks what they produce (dumps against ``gc_model.py``, results and cycles
against the G0 baseline, counter lines).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import dataclasses
import fnmatch
import os
import pathlib
import re
import subprocess
import sys
import threading
import time
import tomllib
from typing import Callable

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "pycore" / "programs" / "hw_tests.toml"
PROGRAMS = ROOT / "pycore" / "programs"
BUILD = ROOT / "build" / "hw"
# G0: every hardware test's result and cycle count on main with the
# collector absent (tools/gc_baseline.py writes it).
BASELINE = ROOT / "pycore" / "tests" / "data" / "gc_baseline_cycles.tsv"
SIM = {
    "single": ROOT / "build" / "sim_img" / "Vtb_container",
    "twocore": ROOT / "build" / "sim_img_twocore" / "Vtb_container",
}
SIM_TARGET = {"single": "pycore-sim-img", "twocore": "pycore-sim-img-twocore"}
DEFAULT_FW_HEX = ROOT / "build" / "excore_fw" / "list_grow.hex"
KINDS = {"run", "trap", "stdout", "coderam", "container", "container_boot", "excore", "make"}
# Kinds that boot a host-built image through managed_entry().
IMAGE_KINDS = {"run", "trap", "stdout", "coderam"}
# Top-level manifest tables that are not test areas.
NOT_AREAS = {"gate"}

# (label, CACHE_EN, MEM_LATENCY, scope). scope "sample" skips entries of the
# SAMPLED_AREAS that are not marked caching = true.
CACHING_CONFIGS = [
    ("cache=0 lat=1", 0, 1, "sample"),
    ("cache=0 lat=4", 0, 4, "sample"),
    ("cache=0 lat=30", 0, 30, "sample"),
    ("cache=1 lat=30", 1, 30, "all"),
]
# Areas whose fixtures run many times longer uncached: the compiler (a
# compile is 10-50x anything else) and the GC loops, which fill the heap on
# purpose. Their caching = true entries stand for the area at cache off.
SAMPLED_AREAS = {"compiler", "gc"}

PASS_RE = re.compile(
    r"^PASS: \S* \S+ (?:tag=(?P<tag>\d+) value=0x(?P<value>[0-9a-fA-F]+)"
    r"|trapped code=(?P<trap>\d+)) cycles=(?P<cycles>\d+)",
    re.M,
)
GC_LINE_RE = re.compile(r"^GC collections=.*$", re.M)


@dataclasses.dataclass
class Test:
    name: str
    area: str
    kind: str = "run"
    core: str = "single"
    src: str | None = None
    file: str | None = None
    stem: str | None = None
    hex: str | None = None
    target: str | None = None
    trap: int | None = None
    cycles: int | None = None
    plusargs: str = ""
    needs: tuple[str, ...] = ()
    legacy: str | None = None
    caching: bool = False
    # A known bug: the run is expected to fail. A failure is reported as
    # XFAIL and does not fail the suite; a pass is XPASS and does, so the
    # marker comes off when the bug is fixed.
    xfail: str | None = None

    @property
    def legacy_target(self) -> str:
        if self.legacy:
            return self.legacy
        if self.kind == "make":
            return self.target or ""
        if self.name.startswith(("container-", "excore-")):
            return "pycore-" + self.name
        return "pycore-img-" + self.name

    @property
    def source(self) -> pathlib.Path:
        if self.file:
            return PROGRAMS / self.file
        return PROGRAMS / f"img_{self.src}.py"


@dataclasses.dataclass(frozen=True)
class Config:
    label: str
    cache_en: int
    latency: int
    scope: str = "all"

    @property
    def slug(self) -> str:
        return f"c{self.cache_en}l{self.latency}"


def config(spec: str) -> Config:
    """``"CACHE_EN,LAT"`` -> Config."""
    cache_en, lat = (int(x) for x in spec.split(","))
    return Config(f"cache={cache_en} lat={lat}", cache_en, lat)


def default_configs() -> list[Config]:
    cache_en = int(os.environ.get("PYCORE_CACHE_EN", "1"))
    lat = int(os.environ.get("PYCORE_MEM_LATENCY", "4"))
    return [Config(f"cache={cache_en} lat={lat}", cache_en, lat)]


@dataclasses.dataclass
class Sim:
    """One simulator invocation's result line."""
    kind: str                  # "return" or "trap"
    code: int                  # tag, or trap code
    value: str                 # hex, lower case ("" for a trap)
    cycles: int


@dataclasses.dataclass
class Result:
    """One test under one configuration."""
    test: Test
    config: Config
    passed: bool
    detail: str
    log: pathlib.Path | None = None
    sims: list[Sim] = dataclasses.field(default_factory=list)
    gc: dict[str, int] = dataclasses.field(default_factory=dict)
    out: pathlib.Path | None = None     # the run's directory ({out})

    @property
    def cycles(self) -> int | None:
        return self.sims[0].cycles if self.sims else None

    @property
    def expected_fail(self) -> bool:
        return bool(self.test.xfail) and not self.passed

    @property
    def ok(self) -> bool:
        """Passed, or failed as its xfail marker says it does."""
        return self.passed != bool(self.test.xfail)

    def text(self) -> str:
        if self.log is None or not self.log.exists():
            return ""
        return self.log.read_text(encoding="utf-8", errors="replace")


def parse_gc_line(text: str) -> dict[str, int]:
    """The ``GC collections=...`` counter line as a dict ({} if absent)."""
    m = GC_LINE_RE.search(text)
    out: dict[str, int] = {}
    if not m:
        return out
    for tok in m.group(0).split()[1:]:
        k, _, v = tok.partition("=")
        if v.isdigit():
            out[k] = int(v)
    return out


def parse_sims(text: str) -> list[Sim]:
    sims = []
    for m in PASS_RE.finditer(text):
        if m.group("trap") is not None:
            sims.append(Sim("trap", int(m.group("trap")), "", int(m.group("cycles"))))
        else:
            sims.append(Sim("return", int(m.group("tag")), m.group("value").lower(),
                            int(m.group("cycles"))))
    return sims


def load_manifest(path: pathlib.Path = MANIFEST) -> list[Test]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    tests: list[Test] = []
    seen: set[str] = set()
    for area, entries in data.items():
        if area in NOT_AREAS:
            continue
        for name, fields in entries.items():
            if name in seen:
                raise SystemExit(f"hw_tests: duplicate test name {name!r}")
            seen.add(name)
            fields = dict(fields)
            if "needs" in fields:
                fields["needs"] = tuple(fields["needs"])
            t = Test(name=name, area=area, **fields)
            if t.kind not in KINDS:
                raise SystemExit(f"hw_tests: {name}: unknown kind {t.kind!r}")
            if t.core not in SIM:
                raise SystemExit(f"hw_tests: {name}: unknown core {t.core!r}")
            tests.append(t)
    return tests


def areas_of(tests: list[Test]) -> list[str]:
    out: list[str] = []
    for t in tests:
        if t.area not in out:
            out.append(t.area)
    return out


def select(
    tests: list[Test],
    areas: list[str],
    names: list[str],
    targets: list[str],
    exclude: list[str],
) -> list[Test]:
    known = set(areas_of(tests))
    for a in areas + exclude:
        if a != "all" and a not in known:
            raise SystemExit(f"hw_tests: unknown area {a!r} (areas: {', '.join(sorted(known))})")
    picked = tests
    if areas and "all" not in areas:
        picked = [t for t in picked if t.area in areas]
    if names:
        picked = [t for t in picked if any(fnmatch.fnmatch(t.name, n) for n in names)]
    if targets:
        picked = [t for t in picked if t.legacy_target in targets]
        missing = set(targets) - {t.legacy_target for t in picked}
        if missing:
            raise SystemExit(f"hw_tests: no test for target(s) {', '.join(sorted(missing))}")
    if exclude:
        picked = [t for t in picked if t.area not in exclude]
    return picked


# -- GC gate sets ----------------------------------------------------------

def load_gates(path: pathlib.Path = MANIFEST) -> dict[str, dict]:
    return tomllib.loads(path.read_text(encoding="utf-8")).get("gate", {})


def gate_spec(name: str, mode: str = "quick", gates: dict[str, dict] | None = None) -> dict:
    """The ``[gate.<name>]`` table with its ``full`` overrides applied in
    MODE=full."""
    gates = load_gates() if gates is None else gates
    if name not in gates:
        raise SystemExit(f"hw_tests: no gate {name!r} (gates: {', '.join(gates)})")
    spec = {k: v for k, v in gates[name].items() if k != "full"}
    if mode == "full":
        spec.update(gates[name].get("full", {}))
    return spec


def baseline_names(path: pathlib.Path = BASELINE) -> set[str]:
    if not path.exists():
        return set()
    with path.open(encoding="utf-8") as fh:
        rows = csv.DictReader((ln for ln in fh if not ln.startswith("#")), delimiter="\t")
        return {r["test"] for r in rows}


def select_set(tests: list[Test], sel: dict, baseline: set[str] | None = None) -> list[Test]:
    """Tests one selector table names.

    ``areas`` and ``names`` (globs) pick their union; with neither, every
    test. Then ``exclude`` (globs) drops names, ``core`` keeps one top,
    ``images`` keeps the kinds that boot a host-built image, and
    ``baseline`` keeps tests that have a G0 row."""
    areas = sel.get("areas", [])
    names = sel.get("names", [])
    if areas or names:
        picked = [t for t in tests if t.area in areas
                  or any(fnmatch.fnmatch(t.name, n) for n in names)]
    else:
        picked = list(tests)
    picked = [t for t in picked if not any(fnmatch.fnmatch(t.name, x) for x in sel.get("exclude", []))]
    if sel.get("core"):
        picked = [t for t in picked if t.core == sel["core"]]
    if sel.get("images"):
        picked = [t for t in picked if t.kind in IMAGE_KINDS]
    if sel.get("baseline"):
        have = baseline_names() if baseline is None else baseline
        picked = [t for t in picked if t.name in have]
    return picked


def gate_tests(spec: dict, tests: list[Test] | None = None) -> list[Test]:
    """Union of the gate's ``sets`` (or of the gate table itself, when it
    has no ``sets``), in manifest order."""
    tests = load_manifest() if tests is None else tests
    sets = spec.get("sets", [spec])
    picked: dict[str, Test] = {}
    for sel in sets:
        for t in select_set(tests, sel):
            picked[t.name] = t
    return [t for t in tests if t.name in picked]


def gate_configs(spec: dict) -> list[Config]:
    """``configs`` entries: ``"CACHE_EN,LAT"`` or ``"caching"`` (the four
    caching-gate configs, sampled as in test-caching)."""
    out: list[Config] = []
    for c in spec.get("configs", ["1,4"]):
        if c == "caching":
            out += [Config(*x) for x in CACHING_CONFIGS]
        else:
            out.append(config(c))
    return out


def _read_meta(path: pathlib.Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
    return meta


def _run(cmd: list[str], log: pathlib.Path, timeout: int = 7200) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout
        )
        rc, out = proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        rc, out = 124, out + f"\n[FAIL] runner timeout after {timeout} s\n"
    log.write_text(" ".join(cmd) + "\n\n" + out, encoding="utf-8")
    return rc, out


class Runner:
    """Builds images under build/hw/<test>/ and runs them.

    ``out`` is where each run's log goes (``<out>/<test>/sim-<config>.log``;
    default build/hw). ``plusargs`` are added to every run and ``extra``
    maps a test name to plusargs for that test only; both go ahead of the
    test's own so they win (Verilog $value$plusargs takes the first match):
    +GC_EN=0 on a GC fixture that asks for +GC_EN=1 runs it with the
    collector off. ``{out}`` in any of them becomes the run's own directory
    ``<out>/<test>/<config>/`` (created first), e.g. +GC_DUMP_EACH={out}.
    """

    def __init__(self, fw_hex: pathlib.Path, python: str, plusargs: str = "",
                 out: pathlib.Path | None = None,
                 extra: dict[str, str] | None = None) -> None:
        self.fw_hex = fw_hex
        self.global_plusargs = plusargs.split()
        self.extra = extra or {}
        self.python = python
        self.out = out or BUILD
        self._built: dict[str, tuple[bool, str]] = {}
        self._build_lock = threading.Lock()
        self._name_locks: dict[str, threading.Lock] = {}

    def work_dir(self, t: Test) -> pathlib.Path:
        d = BUILD / t.name
        d.mkdir(parents=True, exist_ok=True)
        return d

    def log_dir(self, t: Test) -> pathlib.Path:
        d = self.out / t.name
        d.mkdir(parents=True, exist_ok=True)
        return d

    def run_dir(self, t: Test, cfg: Config) -> pathlib.Path:
        return self.out / t.name / cfg.slug

    # -- build (once per test) --------------------------------------------
    def build(self, t: Test) -> tuple[bool, str]:
        with self._build_lock:
            lock = self._name_locks.setdefault(t.name, threading.Lock())
        with lock:
            if t.name not in self._built:
                self._built[t.name] = self._build(t)
            return self._built[t.name]

    def _build(self, t: Test) -> tuple[bool, str]:
        d = self.work_dir(t)
        log = d / "build.log"
        if t.kind in ("run", "coderam"):
            cmd = [
                self.python, "pycore/tools/run_image_test.py",
                "--source", str(t.source.relative_to(ROOT)),
                "--entry", "managed_entry",
                "--dmem-hex", str(d / "dmem.hex"),
                "--meta", str(d / "image.meta"),
            ]
            if t.kind == "coderam":
                cmd += ["--code-ram", "--program-hex", str(d / "code_ram.hex")]
            else:
                cmd += ["--program-hex", str(d / "program.hex")]
        elif t.kind in ("trap", "stdout"):
            cmd = [
                self.python, "pycore/tools/image_from_source.py",
                "--source", str(t.source.relative_to(ROOT)),
                "--program-hex", str(d / "program.hex"),
                "--dmem-hex", str(d / "dmem.hex"),
                "--meta", str(d / "image.meta"),
            ]
            if t.kind == "stdout":
                cmd += ["--expected-tag", "1", "--expected-value", "0"]
        else:
            return True, ""
        rc, out = _run(cmd, log)
        if rc != 0:
            return False, f"image build failed (log: {log.relative_to(ROOT)})"
        return True, ""

    # -- one simulation ---------------------------------------------------
    def added(self, t: Test, cfg: Config) -> list[str]:
        """The runner's plusargs for this run, {out} expanded."""
        toks = self.extra.get(t.name, "").split() + self.global_plusargs
        if any("{out}" in x for x in toks):
            d = self.run_dir(t, cfg)
            d.mkdir(parents=True, exist_ok=True)
            toks = [x.replace("{out}", str(d)) for x in toks]
        return toks

    def plusargs(self, t: Test, cfg: Config) -> list[str]:
        d = BUILD / t.name
        mem = [f"+CACHE_EN={cfg.cache_en}", f"+MEM_LATENCY={cfg.latency}"]
        fw = [f"+FW_HEX={self.fw_hex}"] if t.core == "twocore" else []
        extra = t.plusargs.split()
        added = self.added(t, cfg)
        cycles = [f"+MAX_CYCLES={t.cycles}"] if t.cycles is not None else []
        if t.kind in IMAGE_KINDS:
            meta = _read_meta(d / "image.meta")
            for key in ("HEAP_INIT_PTR", "CODE_RAM_INIT_SLOT"):
                if not meta.get(key):
                    raise RuntimeError(f"image.meta has no {key}")
            base = [f"+DMEM_HEX={d / 'dmem.hex'}", f"+CODE_RAM_HEX={d / 'code_ram.hex'}"]
            if t.kind != "coderam":
                base.insert(0, f"+PROG_HEX={d / 'program.hex'}")
            args = base + fw + [
                "+BOOT_EN=1",
                f"+HEAP_INIT_PTR={meta['HEAP_INIT_PTR']}",
                f"+CODE_RAM_INIT_SLOT={meta['CODE_RAM_INIT_SLOT']}",
            ]
            if t.kind == "trap":
                args += [
                    "+CHECK_ENTRY_RETURN=0",
                    "+EXPECT_TRAP=1",
                    f"+EXPECTED_TRAP_CODE={t.trap}",
                ]
            elif t.kind == "stdout":
                args += [
                    "+CHECK_ENTRY_RETURN=1",
                    "+EXPECTED_TAG=1",
                    "+EXPECTED_VALUE=0",
                    f"+STDOUT_PATH={self.log_dir(t) / f'sim-{cfg.slug}.stdout'}",
                ]
            else:
                for key in ("EXPECTED_TAG", "EXPECTED_VALUE"):
                    if not meta.get(key):
                        raise RuntimeError(f"image.meta has no {key}")
                args += [
                    "+CHECK_ENTRY_RETURN=1",
                    f"+EXPECTED_TAG={meta['EXPECTED_TAG']}",
                    f"+EXPECTED_VALUE={meta['EXPECTED_VALUE']}",
                ]
            return args + cycles + mem + added + extra
        if t.kind == "container":
            return [f"+PROG_HEX={t.hex}", "+BOOT_EN=0"] + added + extra + mem
        if t.kind in ("container_boot", "excore"):
            meta = _read_meta(PROGRAMS / f"{t.stem}.meta")
            if not meta.get("HEAP_INIT_PTR"):
                raise RuntimeError(f"{t.stem}.meta has no HEAP_INIT_PTR")
            return [
                f"+PROG_HEX=pycore/programs/{t.stem}.hex",
                f"+DMEM_HEX=pycore/programs/{t.stem}_dmem.hex",
            ] + fw + [
                "+BOOT_EN=1",
                "+CHECK_ENTRY_RETURN=0",
                f"+HEAP_INIT_PTR={meta['HEAP_INIT_PTR']}",
            ] + added + extra + mem
        raise RuntimeError(f"no plusargs for kind {t.kind}")

    def simulate(self, t: Test, cfg: Config) -> Result:
        log = self.log_dir(t) / f"sim-{cfg.slug}.log"
        res = Result(t, cfg, False, "", log=log)
        if t.kind == "make":
            # prepare() already ran every generator in `needs`. Mark them
            # up to date: a recipe that regenerated pycore/programs/*.hex
            # mid-run raced the tests reading those files.
            cmd = ["make"]
            for need in t.needs:
                cmd += ["-o", need]
            cmd += [
                t.target or "",
                f"PYCORE_CACHE_EN={cfg.cache_en}",
                f"PYCORE_MEM_LATENCY={cfg.latency}",
                f"EXCORE_FW_HEX={self.fw_hex}",
            ]
            added = self.added(t, cfg)
            if added:
                cmd.append(
                    f"PYCORE_MEM_PLUSARGS=+CACHE_EN={cfg.cache_en} +MEM_LATENCY={cfg.latency} "
                    + " ".join(added)
                )
        else:
            try:
                cmd = [str(SIM[t.core])] + self.plusargs(t, cfg)
            except (OSError, RuntimeError) as exc:
                res.detail = str(exc)
                return res
        if "{out}" in " ".join(self.global_plusargs + self.extra.get(t.name, "").split()):
            res.out = self.run_dir(t, cfg)
        rc, out = _run(cmd, log)
        res.sims = parse_sims(out)
        res.gc = parse_gc_line(out)
        if rc != 0 or "[FAIL]" in out or not res.sims:
            tail = [ln for ln in out.splitlines() if "FAIL" in ln or "Error" in ln][:2]
            res.detail = " | ".join(tail) or (f"exit {rc}" if rc else "no PASS line")
            return res
        if t.kind == "stdout":
            want = (PROGRAMS / f"img_{t.src}.stdout").read_text(encoding="utf-8")
            got_path = self.log_dir(t) / f"sim-{cfg.slug}.stdout"
            got = got_path.read_text(encoding="utf-8") if got_path.exists() else ""
            if got != want:
                res.detail = f"stdout differs from img_{t.src}.stdout"
                return res
        res.passed = True
        return res


def configs_for(t: Test, configs: list[Config]) -> list[Config]:
    out = []
    for cfg in configs:
        if cfg.scope == "sample" and t.area in SAMPLED_AREAS and not t.caching:
            continue
        out.append(cfg)
    return out


def prepare(tests: list[Test]) -> None:
    """Build simulators, excore firmware, and generated fixtures once."""
    cores = {t.core for t in tests if t.kind != "make"}
    targets = [SIM_TARGET[c] for c in ("single", "twocore") if c in cores]
    if any(t.core == "twocore" or t.kind == "make" for t in tests):
        targets.append("excore-fw")
    for t in tests:
        for n in t.needs:
            if n not in targets:
                targets.append(n)
    if targets:
        subprocess.run(["make", *targets], cwd=ROOT, check=True)


def status_word(r: Result) -> str:
    if r.test.xfail:
        return "XFAIL" if not r.passed else "XPASS"
    return "PASS" if r.passed else "FAIL"


def run_tests(
    tests: list[Test],
    configs: list[Config],
    *,
    jobs: int = os.cpu_count() or 2,
    plusargs: str = "",
    extra: dict[str, str] | None = None,
    out: pathlib.Path | None = None,
    fw_hex: pathlib.Path = DEFAULT_FW_HEX,
    do_prepare: bool = True,
    echo: Callable[[str], None] | None = print,
) -> list[Result]:
    """Run every test under its configs (configs_for) and return the
    results, longest test first. ``echo`` gets one line per run."""
    if do_prepare and tests:
        prepare(tests)
    runner = Runner(fw_hex.resolve(), sys.executable, plusargs, out=out, extra=extra)
    lock = threading.Lock()
    results: list[Result] = []

    def work(t: Test) -> None:
        ok, detail = runner.build(t)
        for cfg in configs_for(t, configs):
            r = runner.simulate(t, cfg) if ok else Result(t, cfg, False, detail)
            with lock:
                results.append(r)
                if echo:
                    c = f"cycles={r.cycles}" if r.cycles is not None else ""
                    why = r.detail if not r.passed else ""
                    if r.test.xfail:
                        why = f"{why} (known bug: {r.test.xfail})".strip()
                    echo(f"{status_word(r)}  {t.area}/{t.name}  [{cfg.label}]  {c} {why}".rstrip())

    # Longest first: the compiler fixtures would otherwise start last and
    # leave the other workers idle at the end.
    order = sorted(tests, key=lambda t: -(t.cycles or 0))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        list(pool.map(work, order))
    return results


def _echo(line: str) -> None:
    print(line, flush=True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="test names or globs (default: all selected)")
    ap.add_argument("--area", action="append", default=[], help="area to run; 'all' for every area")
    ap.add_argument("--exclude-area", action="append", default=[])
    ap.add_argument("--target", action="append", default=[], help="old make target name")
    ap.add_argument("--config", action="append", default=[], metavar="CACHE,LAT",
                    help="memory config(s); default CACHE_EN/MEM_LATENCY from the environment or 1,4")
    ap.add_argument("--caching", action="store_true", help="run the memory-system gate configs")
    ap.add_argument("--gate", help="run one GC gate's test set with its plusargs ([gate.*] in the manifest)")
    ap.add_argument("--mode", choices=["quick", "full"], default="quick", help="gate mode (with --gate)")
    ap.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--list", action="store_true", help="list the selected tests and exit")
    ap.add_argument("--fw-hex", default=os.environ.get("EXCORE_FW_HEX", str(DEFAULT_FW_HEX)))
    ap.add_argument("--no-prepare", action="store_true", help="skip building sims and fixtures")
    ap.add_argument("--plusargs", default="", help="extra simulator plusargs for every run, ahead of each test's own")
    ap.add_argument("--out", help="directory for the run logs (default build/hw)")
    args = ap.parse_args(argv)

    tests = load_manifest()
    plusargs = args.plusargs
    if args.gate:
        spec = gate_spec(args.gate, args.mode)
        picked = gate_tests(spec, tests)
        if args.names:
            picked = [t for t in picked if any(fnmatch.fnmatch(t.name, n) for n in args.names)]
        plusargs = " ".join([plusargs, spec.get("plusargs", "")]).strip()
        if args.out is None:
            args.out = str(ROOT / "build" / "gc_gates" / args.gate)
    else:
        if not (args.area or args.names or args.target):
            args.area = ["all"]
        picked = select(tests, args.area, args.names, args.target, args.exclude_area)

    if args.caching:
        configs = [Config(*c) for c in CACHING_CONFIGS]
    elif args.config:
        configs = [config(c) for c in args.config]
    elif args.gate:
        configs = gate_configs(spec)
    else:
        configs = default_configs()

    if args.list:
        for t in picked:
            cfgs = ", ".join(c.label for c in configs_for(t, configs))
            mark = "  (xfail)" if t.xfail else ""
            print(f"{t.area:<13} {t.name:<42} {t.kind:<14} {t.core:<8} [{cfgs}]{mark}")
        print(f"{len(picked)} test(s)")
        return 0
    if not picked:
        print("hw_tests: nothing selected", file=sys.stderr)
        return 1

    total_runs = sum(len(configs_for(t, configs)) for t in picked)
    print(
        f"hw_tests: {len(picked)} test(s), {total_runs} run(s), "
        f"configs: {'; '.join(c.label for c in configs)}, {args.jobs} job(s)"
        + (f", plusargs: {plusargs}" if plusargs else ""),
        flush=True,
    )
    start = time.monotonic()
    results = run_tests(
        picked, configs, jobs=args.jobs, plusargs=plusargs,
        out=pathlib.Path(args.out).resolve() if args.out else None,
        fw_hex=pathlib.Path(args.fw_hex), do_prepare=not args.no_prepare, echo=_echo,
    )

    elapsed = time.monotonic() - start
    failed = [r for r in results if not r.ok]
    xfailed = [r for r in results if r.expected_fail]
    by_area: dict[str, list[int]] = {}
    for r in results:
        s = by_area.setdefault(r.test.area, [0, 0, 0])
        s[2 if r.expected_fail else 0 if r.ok else 1] += 1
    print()
    for area in areas_of(picked):
        p, f, x = by_area.get(area, [0, 0, 0])
        print(f"  {area:<13} {p:>4} passed  {f:>3} failed" + (f"  {x} known bug(s)" if x else ""))
    logs = pathlib.Path(args.out).resolve() if args.out else BUILD
    rel = logs.relative_to(ROOT) if logs.is_relative_to(ROOT) else logs
    print(f"hw_tests: {len(results) - len(failed) - len(xfailed)} of {len(results)} run(s) passed"
          + (f", {len(xfailed)} failed as expected (xfail)" if xfailed else "")
          + f" in {elapsed:.0f} s")
    if failed:
        for r in failed:
            why = "passed but is marked xfail; remove the marker" if r.passed else r.detail
            print(f"FAILED {r.test.area}/{r.test.name} [{r.config.label}] {why}  (logs: {rel}/{r.test.name}/)")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
