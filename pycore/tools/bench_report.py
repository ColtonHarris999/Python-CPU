"""One benchmark file per test-suite run.

``hw_tests``, the compile suite, and the host unit tests call
:func:`write_benchmark` when they finish. Each call writes a timestamped
Markdown file and the same rows as JSON under ``build/benchmarks/``, and
appends a line to ``build/benchmarks/index.md``. ``build/`` is gitignored;
CI uploads the directory so a run can be opened later from the workflow's
artifacts.
"""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_DIR = ROOT / "build" / "benchmarks"
_COLUMNS = ("status", "area", "name", "config", "cycles", "compile_cycles", "wall_s", "detail")


def write_benchmark(
    suite: str,
    rows: list[dict],
    *,
    elapsed_s: float,
    passed: int,
    failed: int,
    note: str = "",
    out_dir: pathlib.Path | None = None,
) -> pathlib.Path:
    """Write this run's results and return the Markdown path."""
    out = out_dir or DEFAULT_DIR
    out.mkdir(parents=True, exist_ok=True)
    recorded = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    stamp = recorded.strftime("%Y%m%dT%H%M%SZ")
    slug = _slug(suite)
    stem = f"{stamp}__{slug}"
    payload = {
        "suite": suite,
        "recorded": recorded.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git": _git_sha(),
        "elapsed_s": round(elapsed_s, 3),
        "passed": passed,
        "failed": failed,
        "note": note,
        "rows": rows,
    }
    text = _markdown(payload)
    md = out / f"{stem}.md"
    js = out / f"{stem}.json"
    md.write_text(text, encoding="utf-8")
    js.write_text(json.dumps(payload, indent=1) + "\n", encoding="utf-8")
    (out / "latest.md").write_text(text, encoding="utf-8")
    result = f"{passed} passed, {failed} failed"
    _append_index(
        out,
        f"| {payload['recorded']} | {suite} | {result} | {payload['elapsed_s']:.1f} s | `{md.name}` |",
    )
    return md


def _slug(suite: str) -> str:
    keep = []
    for ch in suite.lower():
        keep.append(ch if ch.isalnum() or ch in "._-" else "-")
    slug = "".join(keep).strip("-")
    return slug or "suite"


def _git_sha() -> str:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=ROOT, check=False, capture_output=True, text=True,
        )
    except OSError:
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _cell(value: object) -> str:
    if value is None or value == "":
        return ""
    if isinstance(value, float):
        return f"{value:.3f}"
    if isinstance(value, int) and not isinstance(value, bool):
        return f"{value:,}"
    return str(value).replace("|", "/").replace("\n", " ")


def _markdown(payload: dict) -> str:
    lines = [
        f"# Benchmark {payload['suite']}",
        "",
        f"Recorded {payload['recorded']}.",
    ]
    if payload["git"]:
        lines.append(f"Git `{payload['git']}`.")
    lines += [
        f"Wall time {payload['elapsed_s']:.1f} s. "
        f"{payload['passed']} passed, {payload['failed']} failed.",
        "",
    ]
    if payload.get("note"):
        lines += [payload["note"], ""]
    lines += [
        "| " + " | ".join(_COLUMNS) + " |",
        "| " + " | ".join("---" if c not in ("cycles", "compile_cycles", "wall_s") else "---:" for c in _COLUMNS) + " |",
    ]
    ordered = sorted(payload["rows"], key=_sort_key)
    for row in ordered:
        lines.append("| " + " | ".join(_cell(row.get(c)) for c in _COLUMNS) + " |")
    lines.append("")
    return "\n".join(lines)


def _sort_key(row: dict) -> tuple:
    cycles = row.get("cycles")
    wall = row.get("wall_s")
    # Slowest first. Missing counts sort last.
    return (
        0 if isinstance(cycles, int) else 1,
        -(cycles if isinstance(cycles, int) else 0),
        0 if isinstance(wall, (int, float)) else 1,
        -(wall if isinstance(wall, (int, float)) else 0),
        str(row.get("name") or ""),
    )


def _append_index(out: pathlib.Path, line: str) -> None:
    index = out / "index.md"
    lock_path = out / ".index.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if not index.exists():
                index.write_text(
                    "# Benchmark runs\n\n"
                    "Newest run on this machine is also `latest.md`.\n\n"
                    "| recorded | suite | result | wall | file |\n"
                    "| --- | --- | --- | ---: | --- |\n",
                    encoding="utf-8",
                )
            with index.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
