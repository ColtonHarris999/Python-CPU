#!/usr/bin/env python3.14
"""Lint and simulate Python programs on PyCore (Verilator).

Commands:
  help   Executive summary of the supported Python subset, plus usage
  lint   Check that a .py file meets the current image-boot requirements
  run    Lint, then simulate on the two-core hart and compare against CPython
"""

from __future__ import annotations

import argparse
import ast
import os
import pathlib
import re
import subprocess
import sys
import types

# Allow ``python pycore/tools/pycore_cli.py`` to find sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dis  # noqa: E402

from image_from_source import (  # noqa: E402
    DEFERRED_OPS,
    SUPPORTED_BINARY_ARGS,
    SUPPORTED_COMPARE_ARGS,
    apply_lfac_injects,
    apply_map_add_seq_injects,
    apply_set_add_seq_injects,
    build_image_from_code,
    fold_function_defaults,
    fold_module_classes,
    iter_code_objects,
    iter_raw_instructions,
    parse_seed_pragmas,
    require_python_3_14,
)
from image_from_source import _is_supported_opname  # noqa: E402
from run_image_test import (  # noqa: E402
    apply_heap_list_capacity_inject,
    expected_tag_value,
    host_entry_result_from_text,
    run_image_test,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

DEFAULT_ENTRY = "managed_entry"
DEFAULT_MAX_CYCLES = 200_000

# Keep in sync with Makefile PYCORE_RTL_SRCS.
PYCORE_RTL_SRCS = (
    "pycore/rtl/pycore_tag_decode.sv",
    "pycore/rtl/pycore_promote.sv",
    "pycore/rtl/pycore_int_alu.sv",
    "pycore/rtl/pycore_mul.sv",
    "pycore/rtl/pycore_div.sv",
    "pycore/rtl/pycore_fpu.sv",
    "pycore/rtl/pycore_complex_alu.sv",
    "pycore/rtl/pycore_string_mem.sv",
    "pycore/rtl/pycore_exec.sv",
    "pycore/rtl/pycore_regfile.sv",
    "pycore/rtl/pycore_fetch.sv",
    "pycore/rtl/pycore_decode.sv",
    "pycore/rtl/pycore_branch.sv",
    "pycore/rtl/pycore_trap.sv",
    "pycore/rtl/pycore_frame.sv",
    "pycore/rtl/pycore_mem_block.sv",
    "pycore/rtl/pycore_mem_bank.sv",
    "pycore/rtl/pycore_imem.sv",
    "pycore/rtl/pycore_code_ram.sv",
    "pycore/rtl/pycore_code_mem.sv",
    "pycore/rtl/pycore_dmem.sv",
    "pycore/rtl/pycore_mem_stage.sv",
    "pycore/rtl/pycore_exc_stack.sv",
    "pycore/rtl/pycore_core.sv",
    "pycore/rtl/pycore_system.sv",
    "excore/rtl/excore_cpu.sv",
    "excore/rtl/excore_mmio.sv",
    "excore/rtl/trap_mailbox.sv",
    "pycore/rtl/pycore_excore_system.sv",
)

EXECUTIVE_SUMMARY = """\
PyCore runs a CPython 3.14 bytecode subset on a SystemVerilog hart, with an
RV32 companion (excore) for list/dict/set growth. A program is allowed when
``image_from_source.py`` can build a boot image from it.

What a program may look like
  - One module. Define ``managed_entry()`` with no arguments and return an
    ``int`` or ``bool`` (that return is what simulation checks). If you do not
    call it at module level, ``run`` appends a call. Type annotations
    (``def f() -> int``) are stripped and ignored.
  - Functions, ``if`` / ``while`` / ``for``, list/dict/set/tuple displays,
    f-strings without format specs, ``try`` / ``except`` / ``else`` / ``finally``,
    ``raise TypeError`` / ``raise TypeError("msg")`` / bare ``raise`` inside
    ``except``.
  - Module-level ``class C:`` with methods and ``@staticmethod`` (no bases,
    no ``@classmethod``, no runtime ``class``).
  - Keyword / ``*args`` / ``**kwargs`` calls on Python functions.

Types that work
  - ``int`` (signed 64-bit), ``bool``, ``float``, ``None``, short strings
    (≤15 UTF-8 bytes inline) and longer strings, ``list``, ``tuple``, ``dict``,
    ``set``, ``range``.
  - Dict/set keys: int, bool, float, str. Negative list/tuple/str indices trap.

Builtins in the boot image
  - Native: ``len``, ``range``, ``set``, ``ord``, ``chr``, ``int()`` (int/bool
    or a digit string), ``str()`` (int/bool/None/str), ``max`` (2-arg int/bool),
    ``print`` (via console MMIO).
  - ROM Python: ``abs``, ``all``, ``any``, ``bool``, ``sum``, ``min`` (incl.
    3+ args), ``map`` / ``zip`` / ``enumerate`` / ``filter`` / ``reversed``
    (these return lists, not iterators), ``sorted`` (``reverse=``, no ``key=``),
    ``list`` / ``dict`` / ``tuple``, ``divmod`` / ``pow`` / ``round``,
    ``bin`` / ``hex`` / ``oct``, ``hasattr`` / ``getattr`` / ``setattr`` /
    ``delattr`` / ``isinstance`` / ``issubclass``, ``exec`` / ``eval`` on a
    precompiled code object (not a source string).
  - Methods: ``list.append/pop/extend/clear``, ``set.add/update``,
    ``str.join/startswith/endswith/find``,
    ``dict.get/keys/items/values/update/pop``.

Not supported yet
  - ``import``, generators / ``async``, ``match``, ``assert``, ``with``,
    ``except*``, closures / nested ``def`` cells, runtime class creation,
    ``super()``, ``compile()``, string-form ``exec`` / ``eval``, files / stdin.
  - Slice assignment; list/tuple slicing. String slicing works when the bounds
    are variables (``s[a:b]``). All-literal slices like ``s[1:]`` are folded by
    CPython to a ``slice`` constant and are rejected — bind the bounds first.
  - Format-spec f-strings (``f"{x:.2f}"``), ``STR * INT``, negative indices.

Semantic ceilings (not lint-detectable)
  - Missing dict keys, unbound locals, and some type errors still halt with a
    hardware trap instead of a catchable Python exception.
  - ``LONG_STR`` ordering and mixed-tag string compares trap.
  - Hardware ``int`` is 64-bit; CPython arbitrary-precision is not.

Machine sources of truth: ``pycore/targets/pycore.json``,
``pycore/docs/bytecode_support.md``, ``pycore_firmware/builtins/builtins.md``.
"""

USAGE = """\
Usage
  python3.14 pycore/tools/pycore_cli.py help
  python3.14 pycore/tools/pycore_cli.py lint PATH.py
  python3.14 pycore/tools/pycore_cli.py run  PATH.py

Makefile
  make help
  make lint-file RUN_SOURCE=path/to/program.py
  make run-file  RUN_SOURCE=path/to/program.py

``run`` builds a CPython 3.14 image, executes ``managed_entry`` on the host
for a golden int/bool, then simulates the two-core design in Verilator and
checks that the hart returns the same tagged value.

Examples
  make lint-file RUN_SOURCE=pycore/programs/example_sum_loop.py
  make run-file  RUN_SOURCE=pycore/programs/example_sum_loop.py
  make run-file  RUN_SOURCE=pycore/programs/img_algo_sort.py RUN_MAX_CYCLES=200000
"""


def _offset_line(co: types.CodeType, offset: int) -> int | None:
    last: int | None = None
    for off, line in dis.findlinestarts(co):
        if off > offset:
            break
        last = line
    return last


def _module_calls_entry(source_text: str, entry: str) -> bool:
    tree = ast.parse(source_text)
    for node in tree.body:
        if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
            continue
        call = node.value
        if (
            isinstance(call.func, ast.Name)
            and call.func.id == entry
            and not call.args
            and not call.keywords
        ):
            return True
    return False


def _has_entry_def(source_text: str, entry: str) -> bool:
    tree = ast.parse(source_text)
    return any(
        isinstance(node, ast.FunctionDef) and node.name == entry
        for node in tree.body
    )


def ensure_entry_call(source_text: str, entry: str) -> str:
    """Append ``entry()`` at module level when the def exists but is not called."""
    if not _has_entry_def(source_text, entry):
        return source_text
    if _module_calls_entry(source_text, entry):
        return source_text
    if source_text and not source_text.endswith("\n"):
        source_text += "\n"
    return source_text + f"{entry}()\n"


def collect_opcode_issues(module_code: types.CodeType) -> list[str]:
    """Report every deferred/unsupported opcode after image folds."""
    issues: list[str] = []
    for co in iter_code_objects(module_code):
        for ins in iter_raw_instructions(co):
            if ins.opname == "CACHE":
                continue
            loc = f"code {co.co_name!r} offset {ins.offset}"
            line = _offset_line(co, ins.offset)
            if line is not None:
                loc = f"line {line}, {loc}"
            if ins.opname == "CALL_INTRINSIC_1":
                if ins.arg == 6:
                    continue
                issues.append(
                    f"{loc}: deferred opcode CALL_INTRINSIC_1 "
                    f"(arg {ins.arg}): {DEFERRED_OPS['CALL_INTRINSIC_1']}"
                )
                continue
            if ins.opname in DEFERRED_OPS:
                issues.append(
                    f"{loc}: deferred opcode {ins.opname}: {DEFERRED_OPS[ins.opname]}"
                )
                continue
            if ins.opname == "SET_FUNCTION_ATTRIBUTE":
                issues.append(
                    f"{loc}: unsupported SET_FUNCTION_ATTRIBUTE flag {ins.arg} "
                    "(only defaults/kwdefaults are folded; closures/annotations "
                    "are not supported)"
                )
                continue
            if not _is_supported_opname(ins.opname):
                issues.append(f"{loc}: unsupported opcode {ins.opname}")
                continue
            if ins.opname == "BINARY_OP" and ins.arg not in SUPPORTED_BINARY_ARGS:
                issues.append(
                    f"{loc}: unsupported BINARY_OP oparg {ins.arg}"
                )
            if ins.opname == "COMPARE_OP" and ins.arg not in SUPPORTED_COMPARE_ARGS:
                issues.append(
                    f"{loc}: unsupported COMPARE_OP oparg {ins.arg}"
                )
    return issues


def prepare_module_code(source_text: str, filename: str):
    """Apply the same folds as ``build_image_from_source_text``."""
    seeds = parse_seed_pragmas(source_text)
    module_code = compile(source_text, filename, "exec")
    module_code = apply_lfac_injects(module_code, source_text)
    module_code = apply_set_add_seq_injects(module_code, source_text)
    module_code = apply_map_add_seq_injects(module_code, source_text)
    module_code, class_specs = fold_module_classes(module_code, source_text)
    module_code, defaults_map, kwdefaults_map = fold_function_defaults(module_code)
    for spec in class_specs:
        for co_id, defaults in spec.method_defaults.items():
            defaults_map[co_id] = defaults
        for co_id, kwdefaults in spec.method_kwdefaults.items():
            kwdefaults_map[co_id] = kwdefaults
    return module_code, seeds, defaults_map, kwdefaults_map, class_specs


def lint_source_text(
    source_text: str,
    filename: str,
    *,
    entry: str | None = None,
) -> list[str]:
    """Return human-readable errors; empty means the image builder accepts it."""
    require_python_3_14()
    errors: list[str] = []
    try:
        tree_text = source_text
        if entry:
            tree_text = ensure_entry_call(source_text, entry)
        module_code, seeds, defaults_map, kwdefaults_map, class_specs = (
            prepare_module_code(tree_text, filename)
        )
    except SyntaxError as exc:
        where = f"{exc.filename or filename}:{exc.lineno}"
        errors.append(f"{where}: SyntaxError: {exc.msg}")
        return errors
    except ValueError as exc:
        errors.append(str(exc))
        return errors

    errors.extend(collect_opcode_issues(module_code))
    if errors:
        return errors

    try:
        build_image_from_code(
            module_code,
            seeds=seeds,
            defaults_map=defaults_map,
            kwdefaults_map=kwdefaults_map,
            class_specs=class_specs,
        )
    except ValueError as exc:
        errors.append(str(exc))
    return errors


def lint_path(source: pathlib.Path, *, entry: str | None = DEFAULT_ENTRY) -> list[str]:
    source = pathlib.Path(source)
    if not source.is_file():
        return [f"{source}: file not found"]
    text = apply_heap_list_capacity_inject(
        source.read_text(encoding="utf-8"), filename=str(source)
    )
    return lint_source_text(text, str(source), entry=entry)


def render_help() -> str:
    return (
        "PyCore — lint and run Python on the bytecode hart\n\n"
        + EXECUTIVE_SUMMARY
        + "\n"
        + USAGE
    )


def cmd_help(_args: argparse.Namespace) -> int:
    text = render_help()
    sys.stdout.write(text if text.endswith("\n") else text + "\n")
    return 0


def cmd_lint(args: argparse.Namespace) -> int:
    source = pathlib.Path(args.source)
    errors = lint_path(source, entry=args.entry)
    if errors:
        print(f"Lint FAIL: {source} ({len(errors)} issue(s))")
        for item in errors:
            print(f"  {item}")
        print("\nRun `python3.14 pycore/tools/pycore_cli.py help` for the supported subset.")
        return 1
    print(f"Lint OK: {source}")
    print("Image-boot accepts this program under the current PyCore subset.")
    if args.entry:
        text = source.read_text(encoding="utf-8") if source.is_file() else ""
        if _has_entry_def(text, args.entry):
            print(f"Entry {args.entry!r} is present (required for `run`).")
        else:
            print(
                f"Note: no {args.entry!r} function. `run` needs a no-arg "
                "entry that returns int or bool."
            )
    return 0


def _parse_meta(path: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key] = value
    return out


def _assemble_excore_fw(build_dir: pathlib.Path) -> pathlib.Path:
    hex_path = build_dir / "excore_fw" / "list_grow.hex"
    hex_path.parent.mkdir(parents=True, exist_ok=True)
    src = REPO_ROOT / "excore" / "fw" / "list_grow.s"
    asm = REPO_ROOT / "excore" / "tools" / "asm_rv32.py"
    python3 = os.environ.get("PYTHON3", "python3")
    proc = subprocess.run(
        [python3, str(asm), str(src), "-o", str(hex_path)],
        check=True,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )
    if proc.stdout:
        sys.stdout.write(proc.stdout)
        sys.stdout.flush()
    return hex_path


def _verilator() -> str:
    return os.environ.get("VERILATOR", "verilator")


def _sv_str(path: pathlib.Path) -> str:
    return f'"{path.resolve()}"'


def _run_verilator(
    *,
    work: pathlib.Path,
    program_hex: pathlib.Path,
    dmem_hex: pathlib.Path,
    string_hex: pathlib.Path,
    meta: dict[str, str],
    max_cycles: int,
    two_core: bool,
    fw_hex: pathlib.Path | None,
    stdout_path: pathlib.Path,
) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
    mdir = work / ("verilator_twocore" if two_core else "verilator")
    heap = meta["HEAP_INIT_PTR"]
    tag = meta["EXPECTED_TAG"]
    value = meta["EXPECTED_VALUE"]
    cmd = [
        _verilator(),
        "-sv",
        "--binary",
        "--timing",
        "+incdir+pycore/rtl",
        "+incdir+excore/rtl/singlecore",
        "--top-module",
        "tb_container",
        f"-GPROG_HEX={_sv_str(program_hex)}",
        f"-GSTRING_HEX={_sv_str(string_hex)}",
        f"-GDMEM_HEX={_sv_str(dmem_hex)}",
        "-GBOOT_EN=1",
        "-GCHECK_ENTRY_RETURN=1",
        f"-GHEAP_INIT_PTR={heap}",
        f"-GEXPECTED_TAG=4'd{tag}",
        f"-GEXPECTED_VALUE=128'd{value}",
        f"-GMAX_CYCLES={max_cycles}",
    ]
    if two_core:
        if fw_hex is None:
            raise ValueError("two-core run requires assembled excore firmware")
        cmd.extend(
            [
                "-GEXCORE_EN=1",
                f"-GFW_HEX={_sv_str(fw_hex)}",
                f"-GSTDOUT_PATH={_sv_str(stdout_path)}",
            ]
        )
    cmd.extend(
        [
            "--Mdir",
            str(mdir),
            "-Wall",
            "-Wno-fatal",
            *PYCORE_RTL_SRCS,
            "pycore/tb/tb_container.sv",
        ]
    )
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return proc, mdir


def cmd_run(args: argparse.Namespace) -> int:
    require_python_3_14()
    source = pathlib.Path(args.source)
    if not source.is_file():
        print(f"run FAIL: {source}: file not found", file=sys.stderr)
        return 1

    raw = source.read_text(encoding="utf-8")
    text = apply_heap_list_capacity_inject(raw, filename=str(source))
    text = ensure_entry_call(text, args.entry)

    errors = lint_source_text(text, str(source), entry=None)
    if errors:
        print(f"Lint FAIL: {source} ({len(errors)} issue(s))")
        for item in errors:
            print(f"  {item}")
        print("\nFix lint issues (or see `pycore_cli.py help`) before simulating.")
        return 1
    print(f"Lint OK: {source}")

    try:
        expected = host_entry_result_from_text(
            text, filename=str(source), entry=args.entry
        )
    except (ValueError, TypeError) as exc:
        print(f"Host golden FAIL: {exc}")
        print(
            f"`run` needs a no-arg {args.entry!r} that returns int or bool "
            "(or `# pycore-expect: <int>`)."
        )
        return 1

    tag, value = expected_tag_value(expected)
    kind = "bool" if isinstance(expected, bool) else "int"
    print(f"Host golden: {kind} {expected!r}  (tag={tag} value=0x{value:x})")

    work = pathlib.Path(args.build_dir)
    if not work.is_absolute():
        work = REPO_ROOT / work
    work.mkdir(parents=True, exist_ok=True)
    program_hex = work / "program.hex"
    dmem_hex = work / "dmem.hex"
    string_hex = work / "string_mem.hex"
    meta_path = work / "image.meta"
    stdout_path = work / "console.txt"

    prepared = work / "prepared.py"
    prepared.write_text(text, encoding="utf-8")
    run_image_test(
        source=prepared,
        entry=args.entry,
        program_hex=program_hex,
        dmem_hex=dmem_hex,
        string_hex=string_hex,
        meta=meta_path,
    )
    meta = _parse_meta(meta_path)
    for key in ("HEAP_INIT_PTR", "EXPECTED_TAG", "EXPECTED_VALUE"):
        if key not in meta:
            print(f"run FAIL: image.meta missing {key}")
            return 1

    fw_hex = None
    two_core = not args.single_core
    if two_core:
        print("Assembling excore firmware...")
        fw_hex = _assemble_excore_fw(work)

    print("Compiling with Verilator (first run is slow)...")
    proc, mdir = _run_verilator(
        work=work,
        program_hex=program_hex,
        dmem_hex=dmem_hex,
        string_hex=string_hex,
        meta=meta,
        max_cycles=args.max_cycles,
        two_core=two_core,
        fw_hex=fw_hex,
        stdout_path=stdout_path,
    )
    combined = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        print(combined)
        print(f"run FAIL: verilator compile exited {proc.returncode}")
        return 1

    sim = mdir / "Vtb_container"
    if not sim.is_file():
        print(combined)
        print(f"run FAIL: missing simulator binary {sim}")
        return 1

    print("Running PyCore simulation...")
    sim_proc = subprocess.run(
        [str(sim)],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    sim_out = (sim_proc.stdout or "") + (sim_proc.stderr or "")
    print(sim_out.rstrip())

    if stdout_path.is_file() and stdout_path.stat().st_size:
        printed = stdout_path.read_text(encoding="utf-8", errors="replace")
        print("--- program stdout ---")
        print(printed, end="" if printed.endswith("\n") else "\n")
        print("----------------------")

    pass_m = re.search(r"^PASS:.*", sim_out, re.MULTILINE)
    if sim_proc.returncode == 0 and pass_m:
        print(
            f"Verified: hart return matches host CPython 3.14 "
            f"({kind} {expected!r})."
        )
        return 0

    print("run FAIL: simulation did not match the host golden (see output above).")
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pycore_cli.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Use the `help` command for the supported-program summary.",
    )
    sub = parser.add_subparsers(dest="command")

    p_help = sub.add_parser("help", help="Executive summary and usage")
    p_help.set_defaults(func=cmd_help)

    p_lint = sub.add_parser("lint", help="Check a Python file against PyCore")
    p_lint.add_argument("source", help="Python source file")
    p_lint.add_argument("--entry", default=DEFAULT_ENTRY)
    p_lint.set_defaults(func=cmd_lint)

    p_run = sub.add_parser("run", help="Lint, simulate with Verilator, check return")
    p_run.add_argument("source", help="Python source file")
    p_run.add_argument("--entry", default=DEFAULT_ENTRY)
    p_run.add_argument("--max-cycles", type=int, default=DEFAULT_MAX_CYCLES)
    p_run.add_argument(
        "--build-dir",
        default="build/pycore_run",
        help="Directory for hex images and the Verilator object dir",
    )
    p_run.add_argument(
        "--single-core",
        action="store_true",
        help="Do not instantiate excore (list/dict/set growth will fatal-trap)",
    )
    p_run.set_defaults(func=cmd_run)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, OSError, ValueError):
        pass
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        sys.stdout.write(render_help())
        return 0
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
