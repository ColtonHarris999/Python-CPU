"""Parser for Callgrind dumps produced with ``--dump-instr=yes``.

Cost lines use the documented compression: ``*`` repeats the previous
position or event, ``+N`` increments the previous position, and event
counts that are omitted are zero. The cost line immediately after a
``calls=`` record is the callee's inclusive cost and is not part of the
caller's self cost. Self costs are what the phase split needs, because
inclusive eval-frame time is almost the entire ``exec``.

Checked against Callgrind 3.24: summing self costs reproduces the
``summary:`` line exactly.
"""

from __future__ import annotations

import bisect
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from cpython_baseline.cycle_model import EVENT_NAMES, blank_events

_CACHE_DESC = re.compile(
    r"desc: (I1|D1|LL) cache: (\d+) B, (\d+) B, (.+)$"
)


@dataclass
class Profile:
    trigger: str
    part: int | None
    summary: dict[str, int]
    caches: dict[str, tuple[int, int, int]]
    functions: dict[str, dict[str, int]] = field(default_factory=dict)
    # Instruction-address self costs, only for addresses the caller asked
    # to keep, and only while the current object is libpython.
    addrs: dict[int, dict[str, int]] = field(default_factory=dict)
    # Lowest instruction address seen for each function, with the object
    # that contained it. Used to name functions Callgrind left anonymous.
    fn_sites: dict[str, tuple[str, int]] = field(default_factory=dict)
    creator: str = ""


def _parse_int(token: str) -> int:
    if token.startswith(("0x", "0X")):
        return int(token, 16)
    return int(token, 10)


def _position(token: str, previous: int) -> int:
    """Callgrind positions are absolute, ``*``, or a signed delta (``+4``, ``-3``)."""
    if token == "*":
        return previous
    if token[0] in "+-":
        return previous + int(token, 10)
    return _parse_int(token)


def _assoc(text: str) -> int:
    text = text.strip()
    if text == "direct-mapped":
        return 1
    # "4-way associative"
    head = text.split("-", 1)[0]
    return int(head)


def parse_callgrind(
    text: str,
    keep_addrs: set[int] | None = None,
    keep_fn: str | None = None,
    fn_names: dict[str, str] | None = None,
    ob_names: dict[str, str] | None = None,
) -> Profile:
    lines = text.splitlines()
    positions: list[str] = []
    events: list[str] = []
    summary: list[int] | None = None
    trigger = ""
    part: int | None = None
    creator = ""
    caches: dict[str, tuple[int, int, int]] = {}

    header_done = False
    for line in lines:
        if line.startswith("creator:"):
            creator = line.split(":", 1)[1].strip()
        elif line.startswith("part:"):
            part = int(line.split(":", 1)[1].strip())
        elif line.startswith("positions:"):
            positions = line.split()[1:]
        elif line.startswith("events:"):
            events = line.split()[1:]
            header_done = True
        elif line.startswith("summary:"):
            summary = [int(tok) for tok in line.split()[1:]]
        elif line.startswith("desc: Trigger:"):
            trigger = line.split(":", 2)[-1].strip()
            if trigger.startswith("Client Request:"):
                trigger = trigger.split(":", 1)[1].strip()
        else:
            matched = _CACHE_DESC.match(line)
            if matched:
                kind, size, line_b, assoc = matched.groups()
                caches[kind] = (int(size), int(line_b), _assoc(assoc))
        if header_done and summary is not None and positions and trigger:
            # Keep scanning the header-only fields; body follows summary.
            break

    if not events or summary is None:
        raise ValueError("callgrind dump is missing events or summary")
    unknown = [name for name in events if name not in EVENT_NAMES]
    if unknown:
        raise ValueError(f"unexpected callgrind events: {unknown}")

    # A dump taken after the counters were zeroed can wrap to uint64.
    if any(value > 2**63 for value in summary):
        raise ValueError(f"callgrind summary for {trigger!r} wrapped; ignoring is the caller's job")

    npos = len(positions)
    nev = len(events)
    instr_at = positions.index("instr") if "instr" in positions else None
    last_pos = [0] * npos
    last_ev = [0] * nev
    totals = blank_events()
    functions: dict[str, dict[str, int]] = {}
    addrs: dict[int, dict[str, int]] = {}
    fn_sites: dict[str, tuple[str, int]] = {}
    fn_names: dict[str, str] = dict(fn_names or {})
    ob_names: dict[str, str] = dict(ob_names or {})
    current_fn: str | None = None
    current_ob = ""
    skip_cost = False
    body = False

    def absorb(tokens: list[str], record: bool) -> None:
        nonlocal last_pos, last_ev
        if len(tokens) < npos:
            raise ValueError(f"cost line has {len(tokens)} tokens, need {npos} positions: {tokens}")
        pos = []
        for i in range(npos):
            pos.append(_position(tokens[i], last_pos[i]))
        ev_vals = []
        for i in range(nev):
            idx = npos + i
            if idx >= len(tokens):
                ev_vals.append(0)
            elif tokens[idx] == "*":
                ev_vals.append(last_ev[i])
            else:
                ev_vals.append(int(tokens[idx]))
        last_pos = pos
        last_ev = ev_vals
        if not record:
            return
        named = blank_events()
        for name, value in zip(events, ev_vals):
            named[name] = value
            totals[name] += value
        if current_fn is not None:
            bucket = functions.get(current_fn)
            if bucket is None:
                bucket = blank_events()
                functions[current_fn] = bucket
            for name in EVENT_NAMES:
                bucket[name] += named[name]
            if instr_at is not None:
                addr = pos[instr_at]
                prev = fn_sites.get(current_fn)
                if prev is None or addr < prev[1]:
                    fn_sites[current_fn] = (current_ob, addr)
        if (
            keep_addrs
            and instr_at is not None
            and "libpython" in current_ob
            and (keep_fn is None or current_fn == keep_fn)
            and pos[instr_at] in keep_addrs
        ):
            addr = pos[instr_at]
            bucket = addrs.get(addr)
            if bucket is None:
                bucket = blank_events()
                addrs[addr] = bucket
            for name in EVENT_NAMES:
                bucket[name] += named[name]

    for line in lines:
        if not body:
            if line.startswith("summary:"):
                body = True
            continue
        if not line or line[0] == "#":
            continue
        if line.startswith("ob="):
            rest = line[3:]
            if rest.startswith("("):
                idx = rest.find(")")
                oid = rest[1:idx]
                name = rest[idx + 1 :].strip()
                if name:
                    ob_names[oid] = name
                    current_ob = name
                else:
                    current_ob = ob_names.get(oid, "")
            else:
                current_ob = rest.strip()
            continue
        if line.startswith("fn="):
            rest = line[3:]
            if rest.startswith("("):
                idx = rest.find(")")
                fid = rest[1:idx]
                name = rest[idx + 1 :].strip()
                if name:
                    fn_names[fid] = name
                    current_fn = name
                else:
                    current_fn = fn_names.get(fid, fid)
            else:
                current_fn = rest.strip() or current_fn
            continue
        if line.startswith(("fl=", "fi=", "fe=", "cob=", "cfi=", "cfn=", "jump=", "jcnd=", "desc:", "totals:")):
            continue
        if line.startswith("calls="):
            skip_cost = True
            continue
        # Cost line. Positions start with a digit, '+', '-', or '*'.
        head = line[0]
        if head not in "0123456789+-*":
            continue
        absorb(line.split(), record=not skip_cost)
        skip_cost = False

    parsed = [totals[name] for name in events]
    # ``totals:`` is the sum of the cost lines and sits at the end of the
    # file, after the header scan has stopped. ``summary:`` is that sum or
    # larger: Callgrind allows it to include cost that was not written out
    # as a cost line. The cycle model uses summary so that cost is kept.
    file_totals = None
    for line in lines:
        if line.startswith("totals:"):
            file_totals = [int(tok) for tok in line.split()[1:]]
    if file_totals is not None and parsed != file_totals[: len(events)]:
        raise ValueError(
            f"callgrind self-cost sum does not match totals for {trigger!r}: "
            f"parsed {parsed} totals {file_totals[: len(events)]}"
        )
    if file_totals is None and parsed != summary[: len(events)]:
        raise ValueError(
            f"callgrind self-cost sum does not match summary for {trigger!r}: "
            f"parsed {parsed} summary {summary[: len(events)]}"
        )
    # ``summary`` is what callgrind_annotate calls the program total. The
    # cost lines (``totals``) can differ by the dump request itself, a
    # handful of instructions. Phase cycles use summary.
    full = blank_events()
    for name, value in zip(events, summary):
        full[name] = value
    return Profile(
        trigger=trigger,
        part=part,
        summary=full,
        caches=caches,
        functions=functions,
        addrs=addrs,
        fn_sites=fn_sites,
        creator=creator,
    )


_SYMBOLS: dict[str, list[tuple[int, int, str]]] = {}


def _anonymous(name: str) -> bool:
    """Callgrind ids, and the raw addresses it prints when a symbol is missing."""
    if name.isdigit():
        return True
    if name.startswith(("0x", "0X")):
        try:
            int(name, 16)
        except ValueError:
            return False
        return True
    return False


def _symbols(path: str) -> list[tuple[int, int, str]]:
    """Exported functions of ``path`` as ``(address, size, name)``, sorted."""
    cached = _SYMBOLS.get(path)
    if cached is not None:
        return cached
    found: list[tuple[int, int, str]] = []
    if path and Path(path).is_file() and shutil.which("readelf"):
        proc = subprocess.run(
            ["readelf", "-Ws", path],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                parts = line.split()
                # "123: value size FUNC bind vis ndx name"
                if len(parts) < 8 or parts[3] != "FUNC":
                    continue
                try:
                    addr = int(parts[1], 16)
                    size = int(parts[2])
                except ValueError:
                    continue
                if addr == 0 or size <= 0:
                    continue
                name = parts[-1].split("@", 1)[0]
                if name:
                    found.append((addr, size, name))
            found.sort()
    _SYMBOLS[path] = found
    return found


def _resolve_site(obj: str, addr: int) -> str:
    syms = _symbols(obj)
    if syms:
        starts = [item[0] for item in syms]
        index = bisect.bisect_right(starts, addr) - 1
        if index >= 0:
            start, size, name = syms[index]
            if start <= addr < start + size:
                return name
    base = Path(obj).name if obj else "anon"
    return f"{base}+0x{addr:x}"


def label_anonymous(profile: Profile) -> None:
    """Replace dump-local function ids with a symbol or ``object+address``.

    A stripped ``libpython`` has no names for its static helpers, so Callgrind
    reports them as ``fn=(706)`` or as a raw address. The id changes with
    translation order. The instruction address does not, and an address that
    falls inside an exported function keeps that function's name.
    """
    renamed: dict[str, dict[str, int]] = {}
    for name, events in profile.functions.items():
        site = profile.fn_sites.get(name)
        label = _resolve_site(site[0], site[1]) if _anonymous(name) and site else name
        bucket = renamed.get(label)
        if bucket is None:
            renamed[label] = events
            continue
        for event in EVENT_NAMES:
            bucket[event] += events[event]
    profile.functions = renamed


def load_dumps(
    directory,
    prefix: str,
    keep_addrs: set[int] | None = None,
    keep_fn: str | None = None,
    entry_addr: int | None = None,
) -> dict[str, Profile]:
    """Read every dump under ``directory`` whose name starts with ``prefix``.

    The file Callgrind writes at process exit has a wrapped summary and is
    skipped. Client-request dumps are keyed by their trigger label.
    """
    from pathlib import Path

    texts: list[str] = []
    for path in sorted(Path(directory).iterdir()):
        if not path.name.startswith(prefix):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "Trigger: Program termination" in text or "summary:" not in text:
            continue
        summary_line = next(line for line in text.splitlines() if line.startswith("summary:"))
        if any(int(tok) > 2**63 for tok in summary_line.split()[1:]):
            continue
        texts.append(text)
    # A function's name is often written only in the dump that first saw it.
    # Later phase files refer to ``fn=(246)`` and would otherwise be anonymous.
    fn_names: dict[str, str] = {}
    ob_names: dict[str, str] = {}
    for text in texts:
        for line in text.splitlines():
            if line.startswith("fn=("):
                idx = line.find(")")
                name = line[idx + 1 :].strip()
                if name:
                    fn_names[line[4:idx]] = name
            elif line.startswith("ob=("):
                idx = line.find(")")
                name = line[idx + 1 :].strip()
                if name:
                    ob_names[line[4:idx]] = name
    # Callgrind prints a function's name only the first time it is translated.
    # If that happened before instrumentation, later dumps say ``fn=(246)``
    # and the name is gone. The entry instruction is still an absolute
    # address, so the id that owns it is the eval loop.
    if entry_addr is not None and keep_fn:
        found_entry = False
        for text in texts:
            current_id: str | None = None
            for line in text.splitlines():
                if line.startswith("fn=("):
                    idx = line.find(")")
                    current_id = line[4:idx]
                    continue
                if current_id and line.startswith("0x"):
                    token = line.split(None, 1)[0]
                    try:
                        addr = int(token, 16)
                    except ValueError:
                        continue
                    if addr == entry_addr:
                        fn_names[current_id] = keep_fn
                        found_entry = True
                        break
            if found_entry:
                break
    found: dict[str, Profile] = {}
    for text in texts:
        profile = parse_callgrind(
            text,
            keep_addrs=keep_addrs,
            keep_fn=keep_fn,
            fn_names=fn_names,
            ob_names=ob_names,
        )
        label_anonymous(profile)
        found[profile.trigger] = profile
    return found
