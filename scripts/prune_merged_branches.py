#!/usr/bin/env python3
"""Remove remote branches that already landed on the default branch.

Keeps:
  * the default branch and any names in KEEP_BRANCHES (default: main ui)
  * heads of open pull requests
  * unmerged branches with no merged PR (parked or in-progress work)

Deletes:
  * branches whose latest associated PR was merged
  * branches with zero commits ahead of the default branch

Usage:
  DRY_RUN=1 scripts/prune_merged_branches.py
  KEEP_BRANCHES="main ui" scripts/prune_merged_branches.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.parse


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def gh_json(args: list[str]):
    proc = run(["gh", *args])
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def gh_api(path: str, method: str = "GET", check: bool = True) -> subprocess.CompletedProcess[str]:
    args = ["gh", "api", path]
    if method != "GET":
        args.extend(["-X", method])
    return run(args, check=check)


def gh_api_json(path: str):
    proc = gh_api(path)
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def classify(
    name: str,
    keep: set[str],
    open_heads: set[str],
    merged_pr: int | None,
    ahead: int,
    status: str | None,
) -> str:
    """Return keep-protected, keep-open, prune-merged-pr, prune-merged, or keep-unmerged."""
    if name in keep:
        return "keep-protected"
    if name in open_heads:
        return "keep-open"
    if merged_pr is not None:
        return "prune-merged-pr"
    if ahead == 0 or status == "identical":
        return "prune-merged"
    return "keep-unmerged"


def main() -> int:
    dry_run = os.environ.get("DRY_RUN", "0").lower() in {"1", "true", "yes"}
    repo = os.environ.get("REPO") or gh_json(
        ["repo", "view", "--json", "nameWithOwner"]
    )["nameWithOwner"]
    default = gh_json(["repo", "view", "--json", "defaultBranchRef"])[
        "defaultBranchRef"
    ]["name"]
    keep = set(os.environ.get("KEEP_BRANCHES", f"main ui {default}").split())
    keep.add(default)

    proc = run(
        ["gh", "api", "--paginate", f"repos/{repo}/branches", "--jq", ".[].name"]
    )
    branches = [line for line in proc.stdout.splitlines() if line]

    open_prs = gh_json(
        [
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--limit",
            "200",
            "--json",
            "headRefName",
        ]
    ) or []
    open_heads = {p["headRefName"] for p in open_prs}

    kept = skipped_open = pruned = failed = 0
    print(f"repo={repo} default={default} dry_run={dry_run} keep={sorted(keep)}")
    print("open PR heads:", " ".join(sorted(open_heads)) or "none")

    for name in branches:
        if name in keep:
            print(f"keep (protected) {name}")
            kept += 1
            continue
        if name in open_heads:
            print(f"keep (open PR) {name}")
            skipped_open += 1
            continue

        merged = (
            gh_json(
                [
                    "pr",
                    "list",
                    "--repo",
                    repo,
                    "--head",
                    name,
                    "--state",
                    "merged",
                    "--limit",
                    "1",
                    "--json",
                    "number",
                ]
            )
            or []
        )
        merged_pr = merged[0]["number"] if merged else None
        ahead = 1
        status = None
        if merged_pr is None:
            encoded = urllib.parse.quote(name, safe="")
            cmp = gh_api_json(f"repos/{repo}/compare/{default}...{encoded}") or {}
            ahead = cmp.get("ahead_by", 1)
            status = cmp.get("status")

        decision = classify(name, keep, open_heads, merged_pr, ahead, status)
        if decision == "keep-unmerged":
            print(f"keep (unmerged, no merged PR) {name}")
            kept += 1
            continue

        if decision == "prune-merged-pr":
            reason = f"merged PR #{merged_pr}"
        else:
            reason = f"merged into {default}"
        print(f"prune ({reason}) {name}")
        if dry_run:
            pruned += 1
            continue
        ref = urllib.parse.quote(f"heads/{name}", safe="/")
        proc = gh_api(f"repos/{repo}/git/refs/{ref}", method="DELETE", check=False)
        if proc.returncode == 0:
            print(f"deleted {name}")
            pruned += 1
        else:
            err = (proc.stderr or proc.stdout or "").strip()
            print(f"WARN: failed to delete {name}: {err}", file=sys.stderr)
            failed += 1

    print(
        f"summary kept={kept} open_pr={skipped_open} pruned={pruned} failed={failed}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
