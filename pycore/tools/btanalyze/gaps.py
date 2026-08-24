"""Coverage-gap, hotspot, backlog, and out-of-scope roadmap analysis.

Severity is *derived* from ``(support, hw_class.fit, in_loop)`` rather than
hard-coded per opcode, so the same matrix retargets to any description file.
The intrinsic ``fit`` tier is crossed with the current ``support`` state: an
opcode a scalar datapath could run but the core rejects today is an ERROR; a
costly-but-supported op inside a loop is a HOTSPOT; object-protocol opcodes are
suppressed (and instead feed the expansion roadmap).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

from .cfg import CFG
from .report import BacklogItem, Finding, RoadmapItem
from .targets import OpInfo, TargetModel


# native first = cheapest / highest value to build next.
_FIT_RANK = {"native": 0, "costly": 1, "heavy": 2}


@dataclass
class GapResult:
    findings: list[Finding]
    backlog: list[BacklogItem]
    roadmap: list[RoadmapItem]
    hw_class_histogram: dict[str, int]
    coverage: dict[str, int]


def _finding_for(info: OpInfo, offset: int, line: int | None, in_loop: bool,
                 *, include_out_of_scope: bool) -> Finding | None:
    """Apply the severity matrix to a single resolved instruction."""
    # 1. Interpreter plumbing is never a hardware gap.
    if info.hw_class == "INTERNAL":
        return None

    # 2. Object-protocol opcodes are out of scope: suppressed unless asked.
    # Partial / bad-oparg rows still surface as warnings when the caller
    # asked for the expansion view — otherwise "execute" vs "partial" on
    # OBJ_EXC is invisible.
    if info.fit == "infeasible":
        if not include_out_of_scope:
            return None
        if info.support == "partial":
            msg = info.message or f"{info.opname} only partially supported"
            return Finding(
                opname=info.opname, offset=offset, line=line, support=info.support,
                hw_class=info.hw_class, fit=info.fit, severity="warn",
                remediation="hardware", needs_leaf=info.needs_leaf, in_loop=in_loop,
                kind="coverage", message=msg, suggestion=info.suggestion, arg=info.arg,
            )
        if not info.arg_supported:
            msg = f"{info.opname} oparg {info.arg} not supported by the target"
            return Finding(
                opname=info.opname, offset=offset, line=line, support=info.support,
                hw_class=info.hw_class, fit=info.fit, severity="warn",
                remediation="hardware", needs_leaf=info.needs_leaf, in_loop=in_loop,
                kind="bad-arg", message=msg, suggestion=info.suggestion, arg=info.arg,
            )
        msg = info.message or (
            f"object-protocol opcode (group {info.obj_group}); "
            "outside the scalar design point"
        )
        return Finding(
            opname=info.opname, offset=offset, line=line, support=info.support,
            hw_class=info.hw_class, fit=info.fit, severity="info",
            remediation="none", needs_leaf=info.needs_leaf, in_loop=in_loop,
            kind="coverage", message=msg, suggestion=info.suggestion, arg=info.arg,
        )

    buildable = info.fit in ("native", "costly", "heavy")

    # 3. The compiler emits something a scalar datapath could run, but the core
    #    cannot today -> correctness gap.
    if info.support in ("reject", "trap") and buildable:
        msg = info.message or f"{info.opname} not executed by the target"
        return Finding(
            opname=info.opname, offset=offset, line=line, support=info.support,
            hw_class=info.hw_class, fit=info.fit, severity="error",
            remediation="hardware", needs_leaf=info.needs_leaf, in_loop=in_loop,
            kind="coverage", message=msg, suggestion=info.suggestion, arg=info.arg,
        )

    # 4. Decoded but incomplete.
    if info.support == "partial":
        msg = info.message or f"{info.opname} only partially supported"
        return Finding(
            opname=info.opname, offset=offset, line=line, support=info.support,
            hw_class=info.hw_class, fit=info.fit, severity="warn",
            remediation="hardware", needs_leaf=info.needs_leaf, in_loop=in_loop,
            kind="coverage", message=msg, suggestion=info.suggestion, arg=info.arg,
        )

    # 5. Supported op handed an oparg the target cannot run.
    if not info.arg_supported:
        msg = f"{info.opname} oparg {info.arg} not supported by the target"
        return Finding(
            opname=info.opname, offset=offset, line=line, support=info.support,
            hw_class=info.hw_class, fit=info.fit, severity="warn",
            remediation="hardware", needs_leaf=info.needs_leaf, in_loop=in_loop,
            kind="bad-arg", message=msg, suggestion=info.suggestion, arg=info.arg,
        )

    # 6/7. Executes correctly but costs cycles; a loop makes it a hotspot.
    if info.support == "execute" and info.fit in ("costly", "heavy"):
        severity = "hotspot" if in_loop else "info"
        msg = (
            f"{info.opname} is multi-cycle ({info.hw_class}); "
            + ("hot loop body" if in_loop else "noteworthy")
        )
        return Finding(
            opname=info.opname, offset=offset, line=line, support=info.support,
            hw_class=info.hw_class, fit=info.fit, severity=severity,
            remediation="hardware-perf", needs_leaf=info.needs_leaf,
            in_loop=in_loop, kind="perf", message=msg,
            suggestion=info.suggestion, arg=info.arg,
        )

    # 8. execute + native -> nothing to flag.
    return None


def _roadmap_member_label(info: OpInfo) -> str:
    if info.opname == "BINARY_OP" and info.arg_object:
        return "BINARY_OP[subscript/matmul]"
    return info.opname


def analyze_gaps(
    fn,
    cfg: CFG,
    target: TargetModel,
    *,
    include_out_of_scope: bool = False,
) -> GapResult:
    findings: list[Finding] = []
    hw_histogram: Counter[str] = Counter()
    coverage: Counter[str] = Counter()

    # backlog: distinct (opcode, hw_class) buildable but not executed.
    backlog_freq: Counter[tuple[str, str]] = Counter()
    backlog_meta: dict[tuple[str, str], OpInfo] = {}

    # roadmap: object opcodes grouped by subsystem.
    roadmap_freq: Counter[str] = Counter()
    roadmap_members: dict[str, set[str]] = {}

    for ins in cfg.instructions:
        info = target.classify(ins.opname, ins.arg)
        in_loop = cfg.is_in_loop(ins.offset)
        hw_histogram[info.hw_class] += 1
        coverage[info.support] += 1

        finding = _finding_for(
            info, ins.offset, ins.line, in_loop,
            include_out_of_scope=include_out_of_scope,
        )
        if finding is not None:
            findings.append(finding)

        if info.fit == "infeasible":
            # The roadmap is descriptive metadata for the suppressed region; it
            # is only assembled when explicitly requested.
            if include_out_of_scope and info.obj_group is not None:
                roadmap_freq[info.obj_group] += 1
                roadmap_members.setdefault(info.obj_group, set()).add(
                    _roadmap_member_label(info)
                )
        elif info.fit in _FIT_RANK and info.support in ("partial", "reject", "trap"):
            # strip markers are already handled (removed in preprocessing), not
            # an unimplemented feature, so they never enter the backlog.
            key = (info.opname, info.hw_class)
            backlog_freq[key] += 1
            backlog_meta.setdefault(key, info)

    backlog = _build_backlog(backlog_freq, backlog_meta)
    roadmap = _build_roadmap(target, roadmap_freq, roadmap_members)
    return GapResult(
        findings=findings,
        backlog=backlog,
        roadmap=roadmap,
        hw_class_histogram=dict(hw_histogram),
        coverage=dict(coverage),
    )


def _build_backlog(
    freq: Counter[tuple[str, str]], meta: dict[tuple[str, str], OpInfo]
) -> list[BacklogItem]:
    items: list[BacklogItem] = []
    for (opcode, hw_class), count in freq.items():
        info = meta[(opcode, hw_class)]
        items.append(
            BacklogItem(
                opcode=opcode, hw_class=hw_class, fit=info.fit,
                needs_leaf=info.needs_leaf, current_module=info.current_module,
                frequency=count,
            )
        )
    items.sort(key=lambda it: (_FIT_RANK.get(it.fit, 99), -it.frequency, it.opcode))
    for rank, item in enumerate(items, start=1):
        item.rank = rank
    return items


def _build_roadmap(
    target: TargetModel,
    freq: Counter[str],
    members: dict[str, set[str]],
) -> list[RoadmapItem]:
    items: list[RoadmapItem] = []
    for group_name, count in freq.items():
        group = target.obj_groups.get(group_name, {})
        items.append(
            RoadmapItem(
                obj_group=group_name,
                distance=int(group.get("distance", 99)),
                needs_subsystem=group.get("needs_subsystem", ""),
                members_present=sorted(members.get(group_name, set())),
                frequency=count,
            )
        )
    items.sort(key=lambda it: (it.distance, -it.frequency, it.obj_group))
    return items
