"""Report data structures and text/JSON rendering.

The analyzer produces a :class:`ProgramReport` (or a :class:`CorpusRollup`
across many programs) made of plain dataclasses. Keeping the data model separate
from the analyses (``gaps``/``folds``) lets both populate the same report and
lets the renderers stay dumb.
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field


# Severity is rendered most-severe first; this order also drives counts.
SEVERITY_ORDER = ("error", "warn", "hotspot", "info")


@dataclass
class Finding:
    """A single hardware-friendly gap at one bytecode site."""

    opname: str
    offset: int
    line: int | None
    support: str
    hw_class: str
    fit: str
    severity: str
    remediation: str
    needs_leaf: str | None
    in_loop: bool
    kind: str  # coverage | bad-arg | perf
    message: str
    suggestion: str | None = None
    arg: int | None = None


@dataclass
class FoldCandidate:
    """A contiguous instruction run a fold unit could fuse."""

    name: str
    opnames: list[str]
    offsets: list[int]  # start offset of each matched site
    line: int | None
    in_loop: bool
    remediation: str
    savings: str | None = None
    needs_ops: list[str] = field(default_factory=list)
    count: int = 0


@dataclass
class BacklogItem:
    """An implement-next recommendation: buildable but not yet executed."""

    opcode: str
    hw_class: str
    fit: str
    needs_leaf: str | None
    current_module: str | None
    frequency: int
    rank: int = 0


@dataclass
class RoadmapItem:
    """An out-of-scope object subsystem, surfaced only on request."""

    obj_group: str
    distance: int
    needs_subsystem: str
    members_present: list[str]
    frequency: int


@dataclass
class Summary:
    instruction_count: int
    coverage: dict[str, int]  # support level -> count
    hw_class_histogram: dict[str, int]
    max_stack_depth: int
    loop_count: int
    finding_counts: dict[str, int]  # severity -> count
    fold_site_count: int = 0

    @property
    def coverage_ratio(self) -> dict[str, float]:
        total = self.instruction_count or 1
        green = self.coverage.get("execute", 0)
        yellow = self.coverage.get("partial", 0) + self.coverage.get("strip", 0)
        red = self.coverage.get("trap", 0) + self.coverage.get("reject", 0)
        return {
            "green": green / total,
            "yellow": yellow / total,
            "red": red / total,
        }


@dataclass
class ProgramReport:
    source: str
    function: str
    target: str
    summary: Summary
    folds: list[FoldCandidate] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    backlog: list[BacklogItem] = field(default_factory=list)
    roadmap: list[RoadmapItem] = field(default_factory=list)


@dataclass
class CorpusRollup:
    target: str
    program_count: int
    reports: list[ProgramReport] = field(default_factory=list)
    backlog: list[BacklogItem] = field(default_factory=list)
    roadmap: list[RoadmapItem] = field(default_factory=list)
    fold_totals: dict[str, int] = field(default_factory=dict)
    finding_counts: dict[str, int] = field(default_factory=dict)


# --------------------------------------------------------------------------- #
# Serialization                                                               #
# --------------------------------------------------------------------------- #

def to_dict(obj) -> dict:
    """Stable, JSON-serializable view of a report dataclass."""
    return dataclasses.asdict(obj)


# --------------------------------------------------------------------------- #
# Text rendering                                                              #
# --------------------------------------------------------------------------- #

_SEVERITY_TAG = {
    "error": "ERROR",
    "warn": "WARN",
    "hotspot": "HOTSPOT",
    "info": "INFO",
}


def _fmt_line(line: int | None) -> str:
    return f"L{line}" if line is not None else "L?"


def _render_summary(s: Summary, lines: list[str]) -> None:
    lines.append("== Summary ==")
    lines.append(f"  instructions:    {s.instruction_count}")
    ratio = s.coverage_ratio
    lines.append(
        "  coverage:        "
        f"green {ratio['green']:.0%} (execute={s.coverage.get('execute', 0)}) | "
        f"yellow {ratio['yellow']:.0%} (partial={s.coverage.get('partial', 0)}, "
        f"strip={s.coverage.get('strip', 0)}) | "
        f"red {ratio['red']:.0%} (trap={s.coverage.get('trap', 0)}, "
        f"reject={s.coverage.get('reject', 0)})"
    )
    histo = ", ".join(
        f"{cls}={n}" for cls, n in sorted(s.hw_class_histogram.items()) if n
    )
    lines.append(f"  hw_class:        {histo}")
    lines.append(f"  max_stack_depth: {s.max_stack_depth}")
    lines.append(f"  loops:           {s.loop_count}")
    counts = ", ".join(
        f"{_SEVERITY_TAG[sev]}={s.finding_counts.get(sev, 0)}"
        for sev in SEVERITY_ORDER
    )
    lines.append(f"  findings:        {counts}")
    lines.append(f"  fold sites:      {s.fold_site_count}")


def _render_folds(folds: list[FoldCandidate], lines: list[str]) -> None:
    lines.append("")
    lines.append("== Fold Candidates ==")
    if not folds:
        lines.append("  (none)")
        return
    for fold in folds:
        loop = " [in loop]" if fold.in_loop else ""
        lines.append(
            f"  {fold.name}: {' '.join(fold.opnames)} "
            f"x{fold.count} @ {_fmt_line(fold.line)}{loop}"
        )
        offsets = ", ".join(str(o) for o in fold.offsets)
        lines.append(f"      sites (offset): {offsets}")
        if fold.savings:
            lines.append(f"      savings: {fold.savings}")
        if fold.needs_ops:
            lines.append(f"      needs implemented first: {', '.join(fold.needs_ops)}")


def _render_findings(findings: list[Finding], lines: list[str]) -> None:
    lines.append("")
    lines.append("== Hardware-Friendly Gaps ==")
    if not findings:
        lines.append("  (none)")
        return
    for f in findings:
        loop = " [in loop]" if f.in_loop else ""
        tag = _SEVERITY_TAG[f.severity]
        lines.append(
            f"  [{tag}] {f.opname} @ offset {f.offset} {_fmt_line(f.line)}{loop}"
        )
        lines.append(
            f"      {f.message} (support={f.support}, hw_class={f.hw_class}, "
            f"fit={f.fit})"
        )
        remediation = f.remediation
        if f.needs_leaf:
            remediation = f"{remediation} @ {f.needs_leaf}"
        lines.append(f"      remediation: {remediation}")
        if f.suggestion:
            lines.append(f"      suggestion: {f.suggestion}")


def _render_backlog(backlog: list[BacklogItem], lines: list[str]) -> None:
    lines.append("")
    lines.append("== Implement-Next Backlog ==")
    if not backlog:
        lines.append("  (none)")
        return
    for item in backlog:
        built = item.current_module if item.current_module else "not built yet"
        lines.append(
            f"  #{item.rank} {item.opcode} "
            f"(hw_class={item.hw_class}, fit={item.fit}, x{item.frequency})"
        )
        lines.append(f"      needs: {item.needs_leaf}  [{built}]")


def _render_roadmap(roadmap: list[RoadmapItem], lines: list[str]) -> None:
    lines.append("")
    lines.append("== Out-of-Scope Expansion Roadmap ==")
    if not roadmap:
        lines.append("  (none seen)")
        return
    for item in roadmap:
        lines.append(
            f"  D{item.distance} {item.obj_group} (x{item.frequency}): "
            f"{item.needs_subsystem}"
        )
        lines.append(f"      opcodes: {', '.join(item.members_present)}")


def render_text(report: ProgramReport, *, include_out_of_scope: bool = False) -> str:
    lines: list[str] = []
    lines.append(f"# Bytecode analysis: {report.source}:{report.function}")
    lines.append(f"# target: {report.target}")
    lines.append("")
    _render_summary(report.summary, lines)
    _render_folds(report.folds, lines)
    _render_findings(report.findings, lines)
    _render_backlog(report.backlog, lines)
    if include_out_of_scope:
        _render_roadmap(report.roadmap, lines)
    return "\n".join(lines) + "\n"


def render_annotated(report: ProgramReport, *, include_out_of_scope: bool = False) -> str:
    """A dis-style listing with folds and findings interleaved per offset."""
    import pathlib

    from bytecode_common import load_function

    from .cfg import build_cfg

    fn = load_function(pathlib.Path(report.source), report.function)
    cfg = build_cfg(fn)

    fold_starts: dict[int, list[str]] = {}
    for fold in report.folds:
        span = len(fold.opnames)
        for offset in fold.offsets:
            fold_starts.setdefault(offset, []).append(f"{fold.name}(x{span})")

    findings_at: dict[int, list[Finding]] = {}
    for f in report.findings:
        if f.severity == "info" and not include_out_of_scope:
            continue
        findings_at.setdefault(f.offset, []).append(f)

    lines: list[str] = []
    lines.append(f"# Annotated listing: {report.source}:{report.function}")
    lines.append("")
    for ins in cfg.instructions:
        loop = "*" if cfg.is_in_loop(ins.offset) else " "
        arg = "" if ins.arg is None else f" {ins.arg}"
        argrepr = f" ({ins.argrepr})" if ins.argrepr else ""
        lines.append(
            f"{loop} {ins.offset:4d} {_fmt_line(ins.line):>5} "
            f"{ins.opname}{arg}{argrepr}"
        )
        for label in fold_starts.get(ins.offset, []):
            lines.append(f"        >> fold: {label}")
        for f in findings_at.get(ins.offset, []):
            lines.append(f"        !! {_SEVERITY_TAG[f.severity]}: {f.message}")
    return "\n".join(lines) + "\n"


def render_corpus_text(
    rollup: CorpusRollup, *, include_out_of_scope: bool = False
) -> str:
    lines: list[str] = []
    lines.append(f"# Corpus analysis ({rollup.program_count} programs)")
    lines.append(f"# target: {rollup.target}")
    lines.append("")
    lines.append("== Aggregate Findings ==")
    counts = ", ".join(
        f"{_SEVERITY_TAG[sev]}={rollup.finding_counts.get(sev, 0)}"
        for sev in SEVERITY_ORDER
    )
    lines.append(f"  {counts}")
    lines.append("")
    lines.append("== Aggregate Fold Candidates ==")
    if rollup.fold_totals:
        for name, total in sorted(
            rollup.fold_totals.items(), key=lambda kv: (-kv[1], kv[0])
        ):
            lines.append(f"  {name}: x{total}")
    else:
        lines.append("  (none)")
    _render_backlog(rollup.backlog, lines)
    if include_out_of_scope:
        _render_roadmap(rollup.roadmap, lines)
    lines.append("")
    for report in rollup.reports:
        lines.append("-" * 70)
        lines.append(render_text(report, include_out_of_scope=include_out_of_scope))
    return "\n".join(lines) + "\n"
