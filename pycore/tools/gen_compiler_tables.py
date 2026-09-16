#!/usr/bin/env python3.14
"""Generate ``pycore_firmware/compiler/tables.py`` (compiler_design.md W-6).

One source of truth: ``pycore/targets/pycore.json`` plus the host ``opcode``,
``keyword``, ``token``, and ``ast`` modules. Output is checked in; CI asserts
regeneration is a no-op. The file is subset-legal (plain ``dict`` / ``list``
literals and ``TOK_*`` / ``ND_*`` integer constants).
"""

from __future__ import annotations

import argparse
import ast
import json
import keyword
import opcode
import pathlib
import sys
import token

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = ROOT / "pycore" / "targets" / "pycore.json"
DEFAULT_OUTPUT = ROOT / "pycore_firmware" / "compiler" / "tables.py"

EMIT_SUPPORT = frozenset({"execute", "partial", "strip"})
# Decode no-ops that never appear as named catalog entries (pycore.json
# groups them under interpreter plumbing) but every co_code stream uses.
PLUMBING_OPS = ("CACHE", "EXTENDED_ARG")


def catalog_opnames(catalog: dict, *, levels: frozenset[str]) -> list[str]:
    names: list[str] = []
    opcodes = catalog.get("opcodes")
    if not isinstance(opcodes, dict):
        raise ValueError("pycore.json: missing opcodes object")
    for name, spec in opcodes.items():
        if not isinstance(spec, dict):
            continue
        if spec.get("support") in levels:
            names.append(name)
    return names


def execute_opnames(catalog: dict) -> list[str]:
    return sorted(catalog_opnames(catalog, levels=frozenset({"execute"})))


def emit_opnames(catalog: dict) -> list[str]:
    names = catalog_opnames(catalog, levels=EMIT_SUPPORT)
    for name in PLUMBING_OPS:
        if name not in names:
            names.append(name)
    return sorted(names)


def build_opmap(opnames: list[str]) -> dict[str, int]:
    missing = [name for name in opnames if name not in opcode.opmap]
    if missing:
        raise ValueError(
            "execute-level ops missing from host opcode.opmap: "
            + ", ".join(missing)
        )
    return {name: int(opcode.opmap[name]) for name in opnames}


def build_keywords() -> dict[str, int]:
    return {word: 1 for word in sorted(keyword.kwlist)}


def build_tok_constants() -> list[tuple[str, int]]:
    """CPython ``token`` kinds as ``TOK_*`` integers, excluding ``N_TOKENS``."""
    rows: list[tuple[str, int]] = []
    for num in sorted(token.tok_name):
        name = token.tok_name[num]
        if name == "N_TOKENS" or name.startswith("NT_"):
            continue
        rows.append((name, int(num)))
    return rows


def build_op_groups() -> tuple[dict[str, int], dict[str, int]]:
    """Exact operator spellings grouped by length for longest-match lexing."""
    op3: dict[str, int] = {}
    op2: dict[str, int] = {}
    for spelling in token.EXACT_TOKEN_TYPES:
        if len(spelling) == 3:
            op3[spelling] = 1
        elif len(spelling) == 2:
            op2[spelling] = 1
    return (
        {key: op3[key] for key in sorted(op3)},
        {key: op2[key] for key in sorted(op2)},
    )


def _format_tok_constants(rows: list[tuple[str, int]]) -> str:
    lines = [f"TOK_{name} = {num}" for name, num in rows]
    lines.append(f"TOK_N_TOKENS = {token.N_TOKENS}")
    return "\n".join(lines)


def _format_int_dict(name: str, mapping: dict[str, int]) -> str:
    lines = [f"{name} = {{"]
    for key in mapping:
        lines.append(f"    {key!r}: {mapping[key]!r},")
    lines.append("}")
    return "\n".join(lines)


def _format_str_list(name: str, values: list[str]) -> str:
    lines = [f"{name} = ["]
    for value in values:
        lines.append(f"    {value!r},")
    lines.append("]")
    return "\n".join(lines)


# ASDL sum types in ``ast`` that are not concrete parse-tree nodes.
_AST_ABSTRACT = frozenset(
    {
        "AST",
        "boolop",
        "cmpop",
        "excepthandler",
        "expr",
        "expr_context",
        "mod",
        "operator",
        "pattern",
        "slice",
        "stmt",
        "type_ignore",
        "type_param",
        "unaryop",
    }
)


def build_nd_kinds() -> list[tuple[str, int]]:
    """CPython ``ast`` concrete node types as ``ND_*`` integers.

    Numbering is alphabetical by the CPython class name so host ``ast.parse``
    shape tests and the firmware SoA kinds stay aligned. Field packing for
    ``nd_a`` / ``nd_b`` / ``nd_c`` is documented in parser.py, not here.
    """
    names: list[str] = []
    for name, obj in vars(ast).items():
        if name in _AST_ABSTRACT:
            continue
        if not isinstance(obj, type):
            continue
        if not issubclass(obj, ast.AST):
            continue
        names.append(name)
    names.sort()
    rows = [(name, i) for i, name in enumerate(names, start=1)]
    const_names = [f"ND_{name.upper()}" for name, _ in rows]
    if len(set(const_names)) != len(const_names):
        raise ValueError("ND_* names collide after uppercasing")
    return rows


def build_nd_dict(rows: list[tuple[str, int]]) -> dict[str, int]:
    return {name: num for name, num in rows}


def build_parse_op_tables(
    nd: dict[str, int],
) -> tuple[dict[str, int], dict[str, int], dict[str, int], dict[str, int], dict[str, int]]:
    """Spelling → kind / precedence tables for the iterative T1 parser."""
    binops = {
        "+": nd["Add"],
        "-": nd["Sub"],
        "*": nd["Mult"],
        "/": nd["Div"],
        "//": nd["FloorDiv"],
        "%": nd["Mod"],
        "**": nd["Pow"],
        "<<": nd["LShift"],
        ">>": nd["RShift"],
        "|": nd["BitOr"],
        "^": nd["BitXor"],
        "&": nd["BitAnd"],
    }
    unops = {
        "+": nd["UAdd"],
        "-": nd["USub"],
        "~": nd["Invert"],
    }
    cmpops = {
        "==": nd["Eq"],
        "!=": nd["NotEq"],
        "<": nd["Lt"],
        ">": nd["Gt"],
        "<=": nd["LtE"],
        ">=": nd["GtE"],
    }
    # Lowest to highest. ``not`` is looser than comparisons; ``**`` is tighter
    # than unary ``+``/``-``/``~``. Matches the Python expression chart.
    prec = {
        "or": 1,
        "and": 2,
        "not": 3,
        "cmp": 4,
        "|": 5,
        "^": 6,
        "&": 7,
        "<<": 8,
        ">>": 8,
        "+": 9,
        "-": 9,
        "*": 10,
        "/": 10,
        "//": 10,
        "%": 10,
        "u": 11,
        "**": 12,
    }
    rightassoc = {"**": 1}
    return binops, unops, cmpops, prec, rightassoc


def _format_nd_constants(rows: list[tuple[str, int]]) -> str:
    lines = [f"ND_{name.upper()} = {num}" for name, num in rows]
    lines.append(f"ND_N_KINDS = {len(rows)}")
    return "\n".join(lines)


def generate_tables_text(catalog_path: pathlib.Path | None = None) -> str:
    path = pathlib.Path(catalog_path) if catalog_path is not None else DEFAULT_CATALOG
    catalog = json.loads(path.read_text(encoding="utf-8"))
    emit_ops = emit_opnames(catalog)
    execute_ops = execute_opnames(catalog)
    opmap = build_opmap(emit_ops)
    keywords = build_keywords()
    tok_rows = build_tok_constants()
    op3, op2 = build_op_groups()
    nd_rows = build_nd_kinds()
    nd = build_nd_dict(nd_rows)
    binops, unops, cmpops, prec, rightassoc = build_parse_op_tables(nd)
    chunks = [
        "# Generated by pycore/tools/gen_compiler_tables.py from",
        "# pycore/targets/pycore.json and the host opcode/keyword/token/ast modules.",
        "# Do not edit. CI: pycore/tests/test_compiler_tables_fresh.py",
        "",
        _format_int_dict("OPMAP", opmap),
        "",
        _format_str_list("EMIT_OPS", emit_ops),
        "",
        _format_str_list("EXECUTE_OPS", execute_ops),
        "",
        _format_int_dict("KEYWORDS", keywords),
        "",
        _format_tok_constants(tok_rows),
        "",
        _format_int_dict("OP3", op3),
        "",
        _format_int_dict("OP2", op2),
        "",
        _format_nd_constants(nd_rows),
        "",
        _format_int_dict("ND", nd),
        "",
        _format_int_dict("BINOPS", binops),
        "",
        _format_int_dict("UNOPS", unops),
        "",
        _format_int_dict("CMPOPS", cmpops),
        "",
        _format_int_dict("PREC", prec),
        "",
        _format_int_dict("RIGHTASSOC", rightassoc),
        "",
    ]
    return "\n".join(chunks)


def write_tables(
    output: pathlib.Path | None = None,
    *,
    catalog: pathlib.Path | None = None,
) -> pathlib.Path:
    dest = pathlib.Path(output) if output is not None else DEFAULT_OUTPUT
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(generate_tables_text(catalog), encoding="utf-8")
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--catalog",
        type=pathlib.Path,
        default=DEFAULT_CATALOG,
        help="Path to pycore.json (default: pycore/targets/pycore.json)",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=DEFAULT_OUTPUT,
        help="Destination tables.py (default: pycore_firmware/compiler/tables.py)",
    )
    args = parser.parse_args(argv)
    write_tables(args.output, catalog=args.catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
