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
"""

from __future__ import annotations

import argparse
import concurrent.futures
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

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "pycore" / "programs" / "hw_tests.toml"
PROGRAMS = ROOT / "pycore" / "programs"
BUILD = ROOT / "build" / "hw"
SIM = {
    "single": ROOT / "build" / "sim_img" / "Vtb_container",
    "twocore": ROOT / "build" / "sim_img_twocore" / "Vtb_container",
}
SIM_TARGET = {"single": "pycore-sim-img", "twocore": "pycore-sim-img-twocore"}
DEFAULT_FW_HEX = ROOT / "build" / "excore_fw" / "list_grow.hex"
KINDS = {"run", "trap", "stdout", "coderam", "container", "container_boot", "excore", "make"}

# (label, CACHE_EN, MEM_LATENCY, scope). scope "sample" skips compiler
# entries that are not marked caching = true.
CACHING_CONFIGS = [
    ("cache=0 lat=1", 0, 1, "sample"),
    ("cache=0 lat=4", 0, 4, "sample"),
    ("cache=0 lat=30", 0, 30, "sample"),
    ("cache=1 lat=30", 1, 30, "all"),
]


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


def load_manifest(path: pathlib.Path = MANIFEST) -> list[Test]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    tests: list[Test] = []
    seen: set[str] = set()
    for area, entries in data.items():
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


def _read_meta(path: pathlib.Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
    return meta


def _run(cmd: list[str], log: pathlib.Path, timeout: int = 7200) -> tuple[int, str]:
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout
    )
    out = proc.stdout + proc.stderr
    log.write_text(" ".join(cmd) + "\n\n" + out, encoding="utf-8")
    return proc.returncode, out


class Runner:
    def __init__(self, fw_hex: pathlib.Path, python: str) -> None:
        self.fw_hex = fw_hex
        self.python = python

    def work_dir(self, t: Test) -> pathlib.Path:
        d = BUILD / t.name
        d.mkdir(parents=True, exist_ok=True)
        return d

    # -- build (once per test) --------------------------------------------
    def build(self, t: Test) -> tuple[bool, str]:
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
    def plusargs(self, t: Test, cfg: Config) -> list[str]:
        d = BUILD / t.name
        mem = [f"+CACHE_EN={cfg.cache_en}", f"+MEM_LATENCY={cfg.latency}"]
        fw = [f"+FW_HEX={self.fw_hex}"] if t.core == "twocore" else []
        extra = t.plusargs.split()
        cycles = [f"+MAX_CYCLES={t.cycles}"] if t.cycles is not None else []
        if t.kind in ("run", "coderam", "trap", "stdout"):
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
                    f"+STDOUT_PATH={d / f'sim-{cfg.slug}.stdout'}",
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
            return args + cycles + mem + extra
        if t.kind == "container":
            return [f"+PROG_HEX={t.hex}", "+BOOT_EN=0"] + extra + mem
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
            ] + extra + mem
        raise RuntimeError(f"no plusargs for kind {t.kind}")

    def simulate(self, t: Test, cfg: Config) -> tuple[bool, str, int | None]:
        d = BUILD / t.name
        log = d / f"sim-{cfg.slug}.log"
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
        else:
            try:
                cmd = [str(SIM[t.core])] + self.plusargs(t, cfg)
            except (OSError, RuntimeError) as exc:
                return False, str(exc), None
        rc, out = _run(cmd, log)
        cycles = None
        m = re.search(r"cycles=(\d+)", out)
        if m:
            cycles = int(m.group(1))
        if rc != 0 or "[FAIL]" in out:
            tail = [ln for ln in out.splitlines() if "FAIL" in ln or "Error" in ln][:2]
            return False, " | ".join(tail) or f"exit {rc}", cycles
        if t.kind == "stdout":
            want = (PROGRAMS / f"img_{t.src}.stdout").read_text(encoding="utf-8")
            got_path = d / f"sim-{cfg.slug}.stdout"
            got = got_path.read_text(encoding="utf-8") if got_path.exists() else ""
            if got != want:
                return False, f"stdout differs from img_{t.src}.stdout", cycles
        return True, "", cycles


def configs_for(t: Test, configs: list[Config]) -> list[Config]:
    out = []
    for cfg in configs:
        if cfg.scope == "sample" and t.area == "compiler" and not t.caching:
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


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="test names or globs (default: all selected)")
    ap.add_argument("--area", action="append", default=[], help="area to run; 'all' for every area")
    ap.add_argument("--exclude-area", action="append", default=[])
    ap.add_argument("--target", action="append", default=[], help="old make target name")
    ap.add_argument("--config", action="append", default=[], metavar="CACHE,LAT",
                    help="memory config(s); default CACHE_EN/MEM_LATENCY from the environment or 1,4")
    ap.add_argument("--caching", action="store_true", help="run the memory-system gate configs")
    ap.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--list", action="store_true", help="list the selected tests and exit")
    ap.add_argument("--fw-hex", default=os.environ.get("EXCORE_FW_HEX", str(DEFAULT_FW_HEX)))
    ap.add_argument("--no-prepare", action="store_true", help="skip building sims and fixtures")
    args = ap.parse_args(argv)

    tests = load_manifest()
    if not (args.area or args.names or args.target):
        args.area = ["all"]
    picked = select(tests, args.area, args.names, args.target, args.exclude_area)

    if args.caching:
        configs = [Config(*c) for c in CACHING_CONFIGS]
    elif args.config:
        configs = []
        for c in args.config:
            cache_en, lat = (int(x) for x in c.split(","))
            configs.append(Config(f"cache={cache_en} lat={lat}", cache_en, lat))
    else:
        cache_en = int(os.environ.get("PYCORE_CACHE_EN", "1"))
        lat = int(os.environ.get("PYCORE_MEM_LATENCY", "4"))
        configs = [Config(f"cache={cache_en} lat={lat}", cache_en, lat)]

    if args.list:
        for t in picked:
            cfgs = ", ".join(c.label for c in configs_for(t, configs))
            print(f"{t.area:<13} {t.name:<42} {t.kind:<14} {t.core:<8} [{cfgs}]")
        print(f"{len(picked)} test(s)")
        return 0
    if not picked:
        print("hw_tests: nothing selected", file=sys.stderr)
        return 1

    if not args.no_prepare:
        prepare(picked)
    runner = Runner(pathlib.Path(args.fw_hex).resolve(), sys.executable)
    total_runs = sum(len(configs_for(t, configs)) for t in picked)
    print(
        f"hw_tests: {len(picked)} test(s), {total_runs} run(s), "
        f"configs: {'; '.join(c.label for c in configs)}, {args.jobs} job(s)",
        flush=True,
    )

    lock = threading.Lock()
    results: list[tuple[Test, str, bool, str, int | None]] = []
    start = time.monotonic()

    def work(t: Test) -> None:
        ok, detail = runner.build(t)
        cfgs = configs_for(t, configs)
        if not ok:
            with lock:
                for cfg in cfgs:
                    results.append((t, cfg.label, False, detail, None))
                    print(f"FAIL  {t.area}/{t.name}  [{cfg.label}]  {detail}", flush=True)
            return
        for cfg in cfgs:
            passed, detail, cycles = runner.simulate(t, cfg)
            with lock:
                results.append((t, cfg.label, passed, detail, cycles))
                c = f"cycles={cycles}" if cycles is not None else ""
                word = "PASS" if passed else "FAIL"
                print(f"{word}  {t.area}/{t.name}  [{cfg.label}]  {c} {detail}".rstrip(), flush=True)

    # Longest first: the compiler fixtures would otherwise start last and
    # leave the other workers idle at the end.
    order = sorted(picked, key=lambda t: -(t.cycles or 0))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        list(pool.map(work, order))

    elapsed = time.monotonic() - start
    failed = [r for r in results if not r[2]]
    by_area: dict[str, list[int]] = {}
    for t, _, passed, _, _ in results:
        s = by_area.setdefault(t.area, [0, 0])
        s[0 if passed else 1] += 1
    print()
    for area in areas_of(picked):
        p, f = by_area.get(area, [0, 0])
        print(f"  {area:<13} {p:>4} passed  {f:>3} failed")
    print(f"hw_tests: {len(results) - len(failed)} of {len(results)} run(s) passed in {elapsed:.0f} s")
    if failed:
        for t, label, _, detail, _ in failed:
            print(f"FAILED {t.area}/{t.name} [{label}] {detail}  (logs: build/hw/{t.name}/)")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
