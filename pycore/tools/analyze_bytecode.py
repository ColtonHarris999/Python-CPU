#!/usr/bin/env python3
"""Analyze CPython 3.14 bytecode for hardware fold candidates and gaps.

Read-only static analyzer. Given a Python source file and a function, it
disassembles the *pre-preprocessing* bytecode and reports, against a retargetable
target description (PyCore by default):

* fold candidates -- contiguous runs a fold unit could fuse, and
* hardware-friendly gaps -- unsupported/partial/costly opcodes, an
  implement-next backlog, and (optionally) an out-of-scope expansion roadmap.

It mirrors ``preprocess.py``'s CLI shape and version gate but never emits hex.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

# Allow ``python pycore/tools/analyze_bytecode.py`` (script dir on sys.path) and
# ``import pycore.tools.analyze_bytecode`` to both find the sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bytecode_common import load_function, require_python_3_14  # noqa: E402
from btanalyze import cfg as cfg_mod  # noqa: E402
from btanalyze import folds as folds_mod  # noqa: E402
from btanalyze import gaps as gaps_mod  # noqa: E402
from btanalyze import report as report_mod  # noqa: E402
from btanalyze.targets import TargetModel, load_target  # noqa: E402

DEFAULT_TARGET = "pycore/targets/pycore.json"


def analyze_program(
    source: pathlib.Path,
    function_name: str,
    target: TargetModel,
    *,
    include_out_of_scope: bool = False,
) -> report_mod.ProgramReport:
    """Run the full pipeline for one (source, function) pair."""
    fn = load_function(source, function_name)
    cfg = cfg_mod.build_cfg(fn)

    fold_result = folds_mod.analyze_folds(cfg, target)
    gap_result = gaps_mod.analyze_gaps(
        fn, cfg, target, include_out_of_scope=include_out_of_scope
    )

    finding_counts = {sev: 0 for sev in report_mod.SEVERITY_ORDER}
    for finding in gap_result.findings:
        finding_counts[finding.severity] = finding_counts.get(finding.severity, 0) + 1

    summary = report_mod.Summary(
        instruction_count=len(cfg.instructions),
        coverage=gap_result.coverage,
        hw_class_histogram=gap_result.hw_class_histogram,
        max_stack_depth=fn.__code__.co_stacksize,
        loop_count=cfg.loop_count,
        finding_counts=finding_counts,
        fold_site_count=fold_result.site_count,
    )
    return report_mod.ProgramReport(
        source=str(source),
        function=function_name,
        target=target.name,
        summary=summary,
        folds=fold_result.candidates,
        findings=gap_result.findings,
        backlog=gap_result.backlog,
        roadmap=gap_result.roadmap,
    )


def _render(report, args) -> str:
    if args.format == "json":
        return json.dumps(report_mod.to_dict(report), indent=2, sort_keys=True) + "\n"
    if getattr(args, "annotate", False):
        # annotate operates on a single program; corpus rollups ignore it.
        if isinstance(report, report_mod.ProgramReport):
            return report_mod.render_annotated(
                report, include_out_of_scope=args.include_out_of_scope
            )
    if isinstance(report, report_mod.CorpusRollup):
        return report_mod.render_corpus_text(
            report, include_out_of_scope=args.include_out_of_scope
        )
    return report_mod.render_text(
        report, include_out_of_scope=args.include_out_of_scope
    )


def _emit(text: str, out: str | None) -> None:
    if out:
        path = pathlib.Path(out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="pycore/programs/fib_iterative.py")
    parser.add_argument("--function", default="managed_entry")
    parser.add_argument("--target", default=DEFAULT_TARGET)
    parser.add_argument("--corpus", default=None, help="directory of .py programs")
    parser.add_argument("--manifest", default=None, help="file listing programs")
    parser.add_argument("--trace", default=None, help="cosim trace (hot-path weighting; stub)")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--out", default=None, help="write output to a file")
    parser.add_argument("--annotate", action="store_true", help="dis-style listing")
    parser.add_argument(
        "--include-out-of-scope",
        action="store_true",
        help="surface suppressed OBJECT findings + the expansion roadmap",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    require_python_3_14()
    args = build_parser().parse_args(argv)
    target = load_target(args.target)

    if args.corpus or args.manifest:
        from btanalyze import corpus as corpus_mod

        rollup = corpus_mod.analyze_corpus(
            analyze_program,
            target,
            corpus_dir=args.corpus,
            manifest=args.manifest,
            function_name=args.function,
            trace=args.trace,
            include_out_of_scope=args.include_out_of_scope,
        )
        _emit(_render(rollup, args), args.out)
        return 0

    report = analyze_program(
        pathlib.Path(args.source),
        args.function,
        target,
        include_out_of_scope=args.include_out_of_scope,
    )
    _emit(_render(report, args), args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
