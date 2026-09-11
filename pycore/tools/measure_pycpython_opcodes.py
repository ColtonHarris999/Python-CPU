#!/usr/bin/env python3.14
"""Compile vendor/pycpython and classify every opcode against PyCore.

Writes ``planning/old/bytecode_compile_progress.md``. Re-run after ISA or
vendor updates:

    python3.14 pycore/tools/measure_pycpython_opcodes.py
"""
from __future__ import annotations

import argparse
import dis
import json
import opcode as opcode_mod
import sys
import types
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent.parent
sys.path.insert(0, str(TOOLS))

from image_from_source import (  # noqa: E402
    DEFERRED_OPS,
    SUPPORTED_BINARY_ARGS,
    SUPPORTED_COMPARE_ARGS,
    _is_supported_opname,
)

ISA_PATH = ROOT / "pycore" / "targets" / "pycore.json"
PKG = ROOT / "vendor" / "pycpython" / "pycpython"
DEFAULT_OUT = ROOT / "planning" / "old" / "bytecode_compile_progress.md"

# Fetch folds EXTENDED_ARG into the next instruction's oparg. It never
# reaches execute() and is not a row in pycore.json opcodes.
FETCH_FULL = {"EXTENDED_ARG"}

NB_OPS = {i: f"{name} ({sym})" for i, (name, sym) in enumerate(opcode_mod._nb_ops)}
INTRINSIC_1 = {i: name for i, name in enumerate(opcode_mod._intrinsic_1_descs)}

SET_FUNCTION_ATTR = {
    1: "MAKE_FUNCTION_DEFAULTS",
    2: "MAKE_FUNCTION_KWDEFAULTS",
    4: "MAKE_FUNCTION_ANNOTATIONS",
    8: "MAKE_FUNCTION_CLOSURE",
}

RAISE_VARARGS = {
    0: "bare raise / reraise active",
    1: "raise exc",
    2: "raise exc from cause",
}

# Human notes overlaying JSON `note` for opcodes that show up in this mix.
EXTRA_NOTES = {
    "EXTENDED_ARG": (
        "Unlisted in JSON. Fetch folds it into the next instruction's oparg; "
        "never reaches execute."
    ),
    "CACHE": (
        "Present in co_code and occupies imem slots. `dis.get_instructions` "
        "omits them even with show_caches=True, so they do not appear in the "
        "logical-opcode tables."
    ),
    "MAKE_FUNCTION": (
        "Function value is the CODE_OBJECT handle. Defaults, annotations, and "
        "closures are not applied at runtime."
    ),
    "CALL": (
        "INT/STR conversion ceilings; builtin positional arity; no "
        "bound-method objects. `print` / `len` / `isinstance` work inside those "
        "ceilings."
    ),
    "CALL_INTRINSIC_1": (
        "JSON execute with supported_opargs [6] (LIST_TO_TUPLE). This mix "
        "also emits 2, 3, and 5, which the image builder rejects."
    ),
    "LOAD_ATTR": (
        "INT/BOOL/STR/CODE_OBJECT/EXCEPTION/TYPE plus native LIST/SET/STR/DICT "
        "methods on main."
    ),
    "LOAD_BUILD_CLASS": (
        "Every `class` statement. pyast.py alone is most of the count. Image "
        "folding is host-only and rejects bases / `__slots__`."
    ),
    "LOAD_LOCALS": (
        "Class-body namespace. Unlisted; travels with LOAD_BUILD_CLASS."
    ),
    "LOAD_COMMON_CONSTANT": (
        "`assert` rewrites. oparg 0 is AssertionError (exceptions plan T7)."
    ),
    "JUMP_BACKWARD_NO_INTERRUPT": (
        "JSON reject. Image prefix `JUMP_*` currently accepts it — a loader leak, "
        "not a runtime implementation."
    ),
    "SET_FUNCTION_ATTRIBUTE": (
        "Image folds flags 1 (defaults) and 2 (kwdefaults) to NOP. Flag 8 "
        "(closure) is rejected. Runtime MAKE_FUNCTION still does not apply "
        "defaults."
    ),
    "RERAISE": (
        "JSON execute for opargs 0 and 1. This mix emits one oparg 2 in "
        "`parser/pegen.py` `_program_text` (Track 9 / `with`), so the opcode "
        "is partial here."
    ),
    "IMPORT_FROM": "`from x import y`. compiler.py / parser / tokenizer dominate.",
    "IMPORT_NAME": "`import x` / `from x import …` preamble.",
    "MAKE_CELL": "Cell creation for nested defs and class bodies.",
    "STORE_DEREF": "Write through a cell (nested def / class).",
    "LOAD_DEREF": "Closure / cell load.",
    "COPY_FREE_VARS": "Copy freevars into a nested function.",
    "YIELD_VALUE": "Generator functions. Concentrated in parser/tokenizer.",
    "RETURN_GENERATOR": "Preamble of those generator functions.",
    "BUILD_SLICE": "`x[a:b:c]` slice object. BINARY_SLICE already covers `x[a:b]`.",
    "STORE_SLICE": "Slice assignment.",
    "LOAD_SUPER_ATTR": "`super().…` (two sites).",
    "GET_YIELD_FROM_ITER": "`yield from`.",
    "SEND": "`yield from` / generator send.",
    "END_SEND": "Generator send unwind.",
    "CLEANUP_THROW": "Generator throw cleanup.",
}


@dataclass
class OpcodeStat:
    name: str
    units: int
    args: Counter[int] = field(default_factory=Counter)
    files: Counter[str] = field(default_factory=Counter)
    json_support: str = "unlisted"
    bucket: str = "unsupported"
    image: str = "rejected"
    note: str = ""


@dataclass
class MixReport:
    files: list[str]
    n_codes: int
    logical_units: int
    raw_units: int
    cache_units: int
    stats: dict[str, OpcodeStat]
    file_units: dict[str, int]
    buckets: dict[str, list[str]]
    isa: dict


def load_isa(path: Path = ISA_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def json_support(isa: dict, opname: str) -> str:
    spec = isa.get("opcodes", {}).get(opname)
    if spec is None:
        return "unlisted"
    return spec.get("support", "unlisted")


def supported_opargs(isa: dict, opname: str) -> set[int] | None:
    spec = isa.get("opcodes", {}).get(opname) or {}
    raw = spec.get("supported_opargs")
    if raw is None:
        return None
    return {int(x) for x in raw}


def classify_opcode(opname: str, used_args: Counter[int], isa: dict) -> str:
    """Map one opcode + its used opargs to full / partial / unsupported.

    Rules:
    - ``EXTENDED_ARG`` is fetch plumbing → full.
    - JSON ``trap`` / ``reject`` / unlisted → unsupported.
    - JSON ``partial`` → partial.
    - JSON ``execute`` / ``strip`` → full, unless ``supported_opargs`` is set
      and this mix uses a value outside that allowlist (then partial).
    """
    if opname in FETCH_FULL:
        return "full"
    spec = isa.get("opcodes", {}).get(opname)
    if spec is None:
        return "unsupported"
    sup = spec.get("support")
    if sup in ("trap", "reject"):
        return "unsupported"
    if sup == "partial":
        return "partial"
    if sup in ("execute", "strip"):
        allow = spec.get("supported_opargs")
        if allow is not None:
            allow_set = {int(x) for x in allow}
            if any(int(a) not in allow_set for a in used_args):
                return "partial"
        return "full"
    return "unsupported"


def image_status(opname: str) -> str:
    if opname == "JUMP_BACKWARD_NO_INTERRUPT":
        return "accepted (JUMP_* prefix leak)"
    if opname == "SET_FUNCTION_ATTRIBUTE":
        return "fold flags 1/2; reject 8"
    if opname == "CALL_INTRINSIC_1":
        return "deferred except oparg 6"
    if opname in DEFERRED_OPS:
        return "deferred"
    if _is_supported_opname(opname):
        return "accepted"
    return "rejected"


def _iter_code_objects(code: types.CodeType):
    yield code
    for const in code.co_consts:
        if isinstance(const, types.CodeType):
            yield from _iter_code_objects(const)


def collect_mix(pkg: Path = PKG, isa: dict | None = None) -> MixReport:
    if not (pkg / "compile.py").is_file():
        raise FileNotFoundError(
            f"PyCPython package missing at {pkg}. "
            "Run: git submodule update --init --recursive"
        )
    isa = isa if isa is not None else load_isa()
    files = sorted(p for p in pkg.rglob("*.py") if p.is_file())
    stats: dict[str, OpcodeStat] = {}
    file_units: dict[str, int] = {}
    n_codes = 0
    raw_units = 0
    cache_units = 0

    for path in files:
        rel = str(path.relative_to(ROOT))
        src = path.read_text(encoding="utf-8")
        code = compile(src, rel, "exec", dont_inherit=True)
        before = 0
        for co in _iter_code_objects(code):
            n_codes += 1
            raw = co.co_code
            raw_units += len(raw) // 2
            for offset in range(0, len(raw), 2):
                if dis.opname[raw[offset]] == "CACHE":
                    cache_units += 1
            for ins in dis.get_instructions(co, show_caches=False):
                st = stats.get(ins.opname)
                if st is None:
                    st = OpcodeStat(name=ins.opname, units=0)
                    stats[ins.opname] = st
                st.units += 1
                st.args[ins.arg if ins.arg is not None else 0] += 1
                st.files[rel] += 1
                before += 1
        file_units[rel] = before

    for st in stats.values():
        st.json_support = json_support(isa, st.name)
        st.bucket = classify_opcode(st.name, st.args, isa)
        st.image = image_status(st.name)
        json_note = (isa.get("opcodes", {}).get(st.name) or {}).get("note") or ""
        extra = EXTRA_NOTES.get(st.name, "")
        st.note = extra or json_note

    buckets: dict[str, list[str]] = {"full": [], "partial": [], "unsupported": []}
    for name, st in sorted(stats.items(), key=lambda kv: -kv[1].units):
        buckets[st.bucket].append(name)

    return MixReport(
        files=[str(p.relative_to(ROOT)) for p in files],
        n_codes=n_codes,
        logical_units=sum(st.units for st in stats.values()),
        raw_units=raw_units,
        cache_units=cache_units,
        stats=stats,
        file_units=file_units,
        buckets=buckets,
        isa=isa,
    )


def _bucket_units(report: MixReport, bucket: str) -> int:
    return sum(report.stats[name].units for name in report.buckets[bucket])


def _pct(n: int, total: int) -> str:
    if total == 0:
        return "0.0%"
    return f"{100.0 * n / total:.1f}%"


def render_markdown(report: MixReport) -> str:
    total = report.logical_units
    full_u = _bucket_units(report, "full")
    part_u = _bucket_units(report, "partial")
    un_u = _bucket_units(report, "unsupported")
    code_ram = int(report.isa.get("limits", {}).get("code_ram_slots", 32768))
    lines: list[str] = []
    a = lines.append

    a("# Bytecode compile progress")
    a("")
    a("**Status:** measured")
    a("**Subject:** bytecode emitted by CPython 3.14.7 when compiling the")
    a("vendored PyCPython compiler (`vendor/pycpython/pycpython/`), classified")
    a("against PyCore's opcode catalog (`pycore/targets/pycore.json`) and")
    a("image acceptance (`pycore/tools/image_from_source.py`).")
    a("**Companion:** [`native_compiler_full_plan.md`](native_compiler_full_plan.md)")
    a("")
    a("This is **not** a list of opcodes PyCPython *emits as a compiler*.")
    a("It is the instruction mix of **PyCPython's own source** — what the")
    a("hart would have to execute to run that compiler without a subsetting")
    a("rewrite.")
    a("")
    a("Generated by `pycore/tools/measure_pycpython_opcodes.py`. Do not edit")
    a("by hand; regenerate after ISA or vendor updates.")
    a("")
    a("## How this was measured")
    a("")
    a("```text")
    a("for each vendor/pycpython/pycpython/**/*.py:")
    a('    co = compile(source, path, "exec", dont_inherit=True)  # CPython 3.14.7')
    a("    walk co and every nested code object")
    a("    count dis.get_instructions(show_caches=False) by opname")
    a("    also count raw co_code units (CACHE occupies imem)")
    a("```")
    a("")
    a(f"- Files: **{len(report.files)}**")
    a(f"- Code objects (module + nested): **{report.n_codes}**")
    a(f"- Logical instruction units (`dis`, CACHE omitted): **{total}**")
    a(f"- Raw `co_code` units (every 2-byte word, including CACHE): **{report.raw_units}**")
    a(f"- Of those, `CACHE` units: **{report.cache_units}**")
    a(f"- Distinct logical opcodes: **{len(report.stats)}**")
    a("")
    a("`dis` omits `CACHE` even with `show_caches=True`. Image boot still")
    a("stores every two-byte unit as one 64-bit imem slot, so the code-RAM")
    a("cost of this mix is the raw count, not the logical count.")
    a("")
    a("Classification uses `pycore.json` `opcodes.*.support`:")
    a("")
    a("| Bucket | JSON `support` | Meaning here |")
    a("| --- | --- | --- |")
    a("| **Fully supported** | `execute` or `strip` | Hardware runs the opcode (type/oparg ceilings in `note` still apply). `EXTENDED_ARG` is included as fetch plumbing. |")
    a("| **Partially supported** | `partial`, or `execute` whose *used* opargs include values outside `supported_opargs` | Hardware runs a documented subset. |")
    a("| **Not supported** | `trap`, `reject`, or unlisted | Trap, image reject, or no row in the catalog. |")
    a("")
    a("An `execute` opcode is **not** moved to partial just because it lists")
    a("`supported_opargs`. That only happens when this mix actually uses a")
    a("disallowed oparg (`CALL_INTRINSIC_1` opargs 2/3/5, and one `RERAISE`")
    a("oparg 2 in `parser/pegen.py`).")
    a("")
    a("The **Image** column is whether `validate_code_object` would currently")
    a("accept the opcode into a `.pycore` image. Prefix rules (`JUMP_*`) make")
    a("that column **optimistic** for `JUMP_BACKWARD_NO_INTERRUPT`.")
    a("")
    a("## Summary")
    a("")
    a("| Bucket | Distinct opcodes | Instruction units | Share of logical units |")
    a("| --- | ---: | ---: | --- |")
    a(f"| Fully supported | {len(report.buckets['full'])} | {full_u} | {_pct(full_u, total)} |")
    a(f"| Partially supported | {len(report.buckets['partial'])} | {part_u} | {_pct(part_u, total)} |")
    a(f"| Not supported | {len(report.buckets['unsupported'])} | {un_u} | {_pct(un_u, total)} |")
    a(f"| **Total (logical)** | **{len(report.stats)}** | **{total}** | **100%** |")
    a("")
    a(f"Code RAM is {code_ram} slots (`pycore.json` `limits.code_ram_slots`).")
    a(f"Logical instructions are about **{total / code_ram:.1f}×** that budget;")
    a(f"raw imem units including CACHE are about **{report.raw_units / code_ram:.1f}×**.")
    a("The unmodified compiler cannot be loaded even if every opcode ran.")
    a("See `planning/compile_plan.md`.")
    a("")
    a("## Fully supported opcodes")
    a("")
    a(f"{len(report.buckets['full'])} opcodes, **{full_u}** units.")
    a("Used `BINARY_OP` and `COMPARE_OP` opargs in this mix all sit inside the")
    a("published allowlists; see [Special opargs](#special-opargs).")
    a("")
    a("| Opcode | Units | JSON | Image | Note |")
    a("| --- | ---: | --- | --- | --- |")
    for name in report.buckets["full"]:
        st = report.stats[name]
        note = st.note.replace("\n", " ")
        a(f"| `{name}` | {st.units} | `{st.json_support}` | {st.image} | {note} |")

    a("")
    a("## Partially supported opcodes")
    a("")
    a(f"{len(report.buckets['partial'])} opcodes, **{part_u}** units.")
    a("")
    a("| Opcode | Units | JSON | Image | Why partial | Used opargs (value → count) |")
    a("| --- | ---: | --- | --- | --- | --- |")
    for name in report.buckets["partial"]:
        st = report.stats[name]
        args = ", ".join(f"{k}→{v}" for k, v in st.args.most_common(12))
        why = st.note.replace("\n", " ")
        a(f"| `{name}` | {st.units} | `{st.json_support}` | {st.image} | {why} | {args} |")

    a("")
    a("## Not supported opcodes")
    a("")
    a(f"{len(report.buckets['unsupported'])} opcodes, **{un_u}** units.")
    a("These block loading unmodified PyCPython onto the hart.")
    a("")
    a("| Opcode | Units | JSON | Image | What it is doing in this mix |")
    a("| --- | ---: | --- | --- | --- |")
    for name in report.buckets["unsupported"]:
        st = report.stats[name]
        note = st.note.replace("\n", " ")
        a(f"| `{name}` | {st.units} | `{st.json_support}` | {st.image} | {note} |")

    a("")
    a("## Special opargs")
    a("")
    a("These opcodes are in the mix and their *arguments* decide whether a")
    a("given site would run on PyCore.")
    a("")

    bin_st = report.stats.get("BINARY_OP")
    if bin_st:
        a("### `BINARY_OP`")
        a("")
        a("JSON `execute`. Image allowlist: add/and/floor-div/lshift/mul/mod/or/")
        a("pow/rshift/sub/true-div/xor plus `NB_SUBSCR`. Inplace forms are the `+13`")
        a("twins. `NB_MATRIX_MULTIPLY` (`@`, 4 / 17) is **not** in the allowlist.")
        a("Every BINARY_OP oparg used by this mix is allowed. No `@`.")
        a("")
        a("| oparg | Name | Units | Image |")
        a("| ---: | --- | ---: | --- |")
        bad = 0
        for arg, n in sorted(bin_st.args.items()):
            ok = "accepted" if arg in SUPPORTED_BINARY_ARGS else "**rejected**"
            if arg not in SUPPORTED_BINARY_ARGS:
                bad += n
            a(f"| {arg} | `{NB_OPS.get(arg, '?')}` | {n} | {ok} |")
        a("")
        a(f"Unallowlisted BINARY_OP units: **{bad}**.")
        a("")

    cmp_st = report.stats.get("COMPARE_OP")
    if cmp_st:
        a("### `COMPARE_OP`")
        a("")
        a("JSON `execute` with a ceiling: numeric + same-tag `SHORT_STR`")
        a("ordering; `LONG_STR` equality only. Image allowlist is the packed")
        a("3.14 selectors below. All used values are accepted.")
        a("")
        a("| packed | Units | Image |")
        a("| ---: | ---: | --- |")
        bad = 0
        for arg, n in sorted(cmp_st.args.items()):
            ok = "accepted" if arg in SUPPORTED_COMPARE_ARGS else "**rejected**"
            if arg not in SUPPORTED_COMPARE_ARGS:
                bad += n
            a(f"| {arg} | {n} | {ok} |")
        a("")
        a(f"Unallowlisted COMPARE_OP units: **{bad}**.")
        a("")

    cin_st = report.stats.get("CALL_INTRINSIC_1")
    if cin_st:
        a("### `CALL_INTRINSIC_1`")
        a("")
        a("Image builder accepts **only** oparg 6 (`INTRINSIC_LIST_TO_TUPLE`).")
        a("")
        a("| oparg | Intrinsic | Units | Image |")
        a("| ---: | --- | ---: | --- |")
        for arg, n in sorted(cin_st.args.items()):
            img = "accepted" if arg == 6 else "**deferred**"
            a(f"| {arg} | `{INTRINSIC_1.get(arg, '?')}` | {n} | {img} |")
        a("")

    sfa_st = report.stats.get("SET_FUNCTION_ATTRIBUTE")
    if sfa_st:
        a("### `SET_FUNCTION_ATTRIBUTE`")
        a("")
        a("JSON `unlisted` / image-time fold. Both used flags matter for nested")
        a("`def` with defaults or closures.")
        a("")
        a("| oparg | Meaning | Units |")
        a("| ---: | --- | ---: |")
        for arg, n in sorted(sfa_st.args.items()):
            a(f"| {arg} | {SET_FUNCTION_ATTR.get(arg, '?')} | {n} |")
        a("")

    raise_st = report.stats.get("RAISE_VARARGS")
    if raise_st:
        a("### `RAISE_VARARGS`")
        a("")
        a("JSON `partial`. opargs 0 and 1 execute; oparg 2 (`raise X from Y`)")
        a("does not.")
        a("")
        a("| oparg | Meaning | Units | Runtime |")
        a("| ---: | --- | ---: | --- |")
        allow = supported_opargs(report.isa, "RAISE_VARARGS") or set()
        for arg, n in sorted(raise_st.args.items()):
            rt = "execute" if arg in allow else "**unsupported**"
            a(f"| {arg} | {RAISE_VARARGS.get(arg, '?')} | {n} | {rt} |")
        a("")

    conv_st = report.stats.get("CONVERT_VALUE")
    if conv_st:
        a("### `CONVERT_VALUE`")
        a("")
        a("JSON `partial`: opargs 1/2/3 (`!s` / `!r` / `!a`). LONG_STR only")
        a("oparg 1.")
        a("")
        a("| oparg | Units |")
        a("| ---: | ---: |")
        for arg, n in sorted(conv_st.args.items()):
            a(f"| {arg} | {n} |")
        a("")

    reraise_st = report.stats.get("RERAISE")
    if reraise_st:
        a("### `RERAISE`")
        a("")
        a("JSON `execute` with `supported_opargs` `[0, 1]`. oparg 2 is Track 9")
        a("(`with`). One unit in this mix (`parser/pegen.py` `_program_text`)")
        a("uses oparg 2, so the opcode is classified **partial**.")
        a("")
        a("| oparg | Units | Runtime |")
        a("| ---: | ---: | --- |")
        allow = supported_opargs(report.isa, "RERAISE") or set()
        for arg, n in sorted(reraise_st.args.items()):
            rt = "execute" if arg in allow else "**unsupported**"
            a(f"| {arg} | {n} | {rt} |")
        a("")

    a("## Per-file instruction units")
    a("")
    a("| File | Logical units | Share |")
    a("| --- | ---: | --- |")
    for path, n in sorted(report.file_units.items(), key=lambda kv: -kv[1]):
        a(f"| `{path}` | {n} | {_pct(n, total)} |")

    a("")
    a("## Per-file: opcodes that are not fully supported")
    a("")
    a("Every file that emits a partial or unsupported opcode. Counts are")
    a("logical instruction units in that file's code objects (including nested).")
    a("")
    a("| File | Partial / unsupported opcodes (units) |")
    a("| --- | --- |")
    file_ops: dict[str, Counter[str]] = defaultdict(Counter)
    for st in report.stats.values():
        if st.bucket == "full":
            continue
        for path, n in st.files.items():
            file_ops[path][st.name] += n
    for path, ctr in sorted(file_ops.items(), key=lambda kv: kv[0]):
        parts = ", ".join(f"`{k}` {v}" for k, v in sorted(ctr.items()))
        a(f"| `{path}` | {parts} |")

    a("")
    a("## Unsupported opcodes by file")
    a("")
    a("| File | Unsupported units | Distinct trap/reject/unlisted ops |")
    a("| --- | ---: | --- |")
    file_un: dict[str, Counter[str]] = defaultdict(Counter)
    for st in report.stats.values():
        if st.bucket != "unsupported":
            continue
        for path, n in st.files.items():
            file_un[path][st.name] += n
    for path, ctr in sorted(file_un.items(), key=lambda kv: -sum(kv[1].values())):
        parts = ", ".join(f"`{k}` {v}" for k, v in ctr.most_common())
        a(f"| `{path}` | {sum(ctr.values())} | {parts} |")

    a("")
    a("## What this means for the firmware compiler")
    a("")
    a("1. **Do not load this mix onto the hart.** "
      f"{un_u} trap/reject/unlisted units plus MAKE_FUNCTION/CALL partial")
    a("   semantics plus a code-RAM overrun (logical "
      f"{total / code_ram:.1f}×, raw {report.raw_units / code_ram:.1f}×).")
    a("2. **Highest-count unsupported ops to design around in the firmware")
    a("   compiler:** `LOAD_COMMON_CONSTANT` (assert), `LOAD_BUILD_CLASS`")
    a("   (classes), `IMPORT_NAME` / `IMPORT_FROM` (imports), plus")
    a("   `LOAD_LOCALS` / `MAKE_CELL` / `STORE_DEREF` which ride along with")
    a("   class bodies and nested defs.")
    a("3. **Closures are uncommon but real.** `LOAD_DEREF`, `MAKE_CELL`,")
    a("   `COPY_FREE_VARS`, `STORE_DEREF`, and `SET_FUNCTION_ATTRIBUTE` flag 8")
    a("   sit on the same nested functions. The firmware compiler should reject")
    a("   nested defs that need cells rather than emitting these.")
    a("4. **Generators are concentrated in `parser/` and `tokenizer.py`.** A")
    a("   PEG-free LL(1) parser does not need `YIELD_VALUE`.")
    a("5. **`JUMP_BACKWARD_NO_INTERRUPT` is reject in the ISA.** Fix the image")
    a("   builder prefix leak before any generator-loop experiment, or the")
    a("   loader will accept a jump the execute loop does not implement.")
    a("6. **`CALL_INTRINSIC_1` opargs 2/3/5** (`IMPORT_STAR`,")
    a("   `STOPITERATION_ERROR`, `UNARY_POSITIVE`) need either runtime support")
    a("   or firmware-compiler rewrites (`+x` → `x`, import-star rejected).")
    a("7. **Fully-supported count is necessary but not sufficient.** Vendor")
    a("   `LOAD_ATTR` on LIST is fine on current main (native methods), but")
    a("   other tags and `append`-shaped sites still need the subset rewrite.")
    a("")
    a("The compile plan therefore does **not** try to execute this opcode mix. The")
    a("firmware compiler is a subset rewrite that only emits (and only uses)")
    a("allowlisted ops.")
    a("")
    a("## Reproducing")
    a("")
    a("```bash")
    a("python3.14 pycore/tools/measure_pycpython_opcodes.py")
    a("```")
    a("")
    a("Requires the `vendor/pycpython` submodule and CPython 3.14. The")
    a("script writes this file.")
    a("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_OUT,
        help="markdown path (default: planning/old/bytecode_compile_progress.md)",
    )
    args = parser.parse_args(argv)
    report = collect_mix()
    text = render_markdown(report)
    out = args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(
        f"wrote {out} ({out.stat().st_size} bytes)",
        file=sys.stderr,
    )
    print(
        f"files={len(report.files)} codes={report.n_codes} "
        f"logical={report.logical_units} raw={report.raw_units} "
        f"cache={report.cache_units} ops={len(report.stats)}",
        file=sys.stderr,
    )
    print(
        f"full={len(report.buckets['full'])}/{_bucket_units(report, 'full')} "
        f"partial={len(report.buckets['partial'])}/{_bucket_units(report, 'partial')} "
        f"unsupported={len(report.buckets['unsupported'])}/{_bucket_units(report, 'unsupported')}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
