"""Corpus iteration and rollup across many programs.

Runs the single-program pipeline over a directory of ``.py`` files (or an
explicit manifest) and aggregates the per-program reports: fold totals, finding
counts, a merged implement-next backlog, and a merged out-of-scope roadmap.

``--trace`` hot-path weighting is stubbed: the interface accepts a cosim trace
path now so the CLI is stable, but weighting is left for a later milestone.
"""

from __future__ import annotations

import pathlib
from collections import Counter
from typing import Callable

from .report import (
    BacklogItem,
    CorpusRollup,
    ProgramReport,
    RoadmapItem,
    SEVERITY_ORDER,
)
from .targets import TargetModel

_FIT_RANK = {"native": 0, "costly": 1, "heavy": 2}


def _iter_program_specs(
    corpus_dir: str | None,
    manifest: str | None,
    function_name: str,
) -> list[tuple[pathlib.Path, str]]:
    specs: list[tuple[pathlib.Path, str]] = []
    if manifest:
        for raw in pathlib.Path(manifest).read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            path, _, func = line.partition("::")
            specs.append((pathlib.Path(path), func or function_name))
    if corpus_dir:
        for path in sorted(pathlib.Path(corpus_dir).glob("*.py")):
            specs.append((path, function_name))
    return specs


def analyze_corpus(
    analyze_program: Callable[..., ProgramReport],
    target: TargetModel,
    *,
    corpus_dir: str | None = None,
    manifest: str | None = None,
    function_name: str = "managed_entry",
    trace: str | None = None,  # stub: hot-path weighting not yet implemented
    include_out_of_scope: bool = False,
) -> CorpusRollup:
    specs = _iter_program_specs(corpus_dir, manifest, function_name)

    reports: list[ProgramReport] = []
    fold_totals: Counter[str] = Counter()
    finding_counts: Counter[str] = Counter()
    backlog_freq: Counter[tuple[str, str]] = Counter()
    backlog_meta: dict[tuple[str, str], BacklogItem] = {}
    roadmap_freq: Counter[str] = Counter()
    roadmap_members: dict[str, set[str]] = {}
    roadmap_meta: dict[str, RoadmapItem] = {}

    for source, func in specs:
        try:
            report = analyze_program(
                source, func, target, include_out_of_scope=include_out_of_scope
            )
        except (ValueError, SyntaxError) as exc:  # skip unloadable fixtures
            print(f"# skipped {source}: {exc}")
            continue
        reports.append(report)

        for fold in report.folds:
            fold_totals[fold.name] += fold.count
        for sev in SEVERITY_ORDER:
            finding_counts[sev] += report.summary.finding_counts.get(sev, 0)
        for item in report.backlog:
            key = (item.opcode, item.hw_class)
            backlog_freq[key] += item.frequency
            backlog_meta.setdefault(key, item)
        for item in report.roadmap:
            roadmap_freq[item.obj_group] += item.frequency
            roadmap_members.setdefault(item.obj_group, set()).update(item.members_present)
            roadmap_meta.setdefault(item.obj_group, item)

    backlog = _merge_backlog(backlog_freq, backlog_meta)
    roadmap = _merge_roadmap(roadmap_freq, roadmap_members, roadmap_meta)
    return CorpusRollup(
        target=target.name,
        program_count=len(reports),
        reports=reports,
        backlog=backlog,
        roadmap=roadmap,
        fold_totals=dict(fold_totals),
        finding_counts=dict(finding_counts),
    )


def _merge_backlog(
    freq: Counter[tuple[str, str]], meta: dict[tuple[str, str], BacklogItem]
) -> list[BacklogItem]:
    items: list[BacklogItem] = []
    for key, count in freq.items():
        base = meta[key]
        items.append(
            BacklogItem(
                opcode=base.opcode, hw_class=base.hw_class, fit=base.fit,
                needs_leaf=base.needs_leaf, current_module=base.current_module,
                frequency=count,
            )
        )
    items.sort(key=lambda it: (_FIT_RANK.get(it.fit, 99), -it.frequency, it.opcode))
    for rank, item in enumerate(items, start=1):
        item.rank = rank
    return items


def _merge_roadmap(
    freq: Counter[str],
    members: dict[str, set[str]],
    meta: dict[str, RoadmapItem],
) -> list[RoadmapItem]:
    items: list[RoadmapItem] = []
    for group_name, count in freq.items():
        base = meta[group_name]
        items.append(
            RoadmapItem(
                obj_group=group_name, distance=base.distance,
                needs_subsystem=base.needs_subsystem,
                members_present=sorted(members.get(group_name, set())),
                frequency=count,
            )
        )
    items.sort(key=lambda it: (it.distance, -it.frequency, it.obj_group))
    return items
