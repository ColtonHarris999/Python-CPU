#!/usr/bin/env python3.14
"""Generate a PyCore image and expected result from a Python source module."""

from __future__ import annotations

import argparse
import ast
import pathlib
import types

from encoding import TAG_BOOL, TAG_INT, VAL_MASK
from image_from_source import (
    build_image_from_source_text,
    parse_seed_pragmas,
    require_python_3_14,
    write_image_outputs,
)


class _RemoveEntryCall(ast.NodeTransformer):
    """Drop module-level ``entry()`` so seeds can be wired before the call."""

    def __init__(self, entry: str) -> None:
        self.entry = entry

    def visit_Expr(self, node: ast.Expr) -> ast.AST | None:
        self.generic_visit(node)
        val = node.value
        if (
            isinstance(val, ast.Call)
            and isinstance(val.func, ast.Name)
            and val.func.id == self.entry
            and not val.args
            and not val.keywords
        ):
            return None
        return node


def host_entry_result(source: pathlib.Path, entry: str) -> int | bool:
    source = pathlib.Path(source)
    source_text = source.read_text(encoding="utf-8")
    seeds = parse_seed_pragmas(source_text)

    tree = ast.parse(source_text, filename=str(source))
    tree = _RemoveEntryCall(entry).visit(tree)
    ast.fix_missing_locations(tree)

    namespace: dict[str, object] = {"__name__": "__pycore_host__"}
    exec(compile(tree, str(source), "exec"), namespace)

    # Wire SEED_TYPE / SEED_TYPE_METHOD / SEED_INSTANCE after defs exist.
    methods_by_type: dict[str, list] = {}
    for m in seeds.type_methods:
        methods_by_type.setdefault(m.type_name, []).append(m)

    type_objs: dict[str, type] = {}
    for spec in seeds.types:
        body: dict[str, object] = {name: val for name, val in spec.attrs}
        for mspec in methods_by_type.get(spec.name, []):
            fn = namespace.get(mspec.func_name)
            if not callable(fn):
                raise ValueError(
                    f"host seed: function {mspec.func_name!r} not found for "
                    f"SEED_TYPE_METHOD {spec.name}.{mspec.attr_name}"
                )
            body[mspec.attr_name] = fn
        typ = type(spec.name, (), body)
        type_objs[spec.name] = typ
        namespace[spec.name] = typ

    for mspec in seeds.type_methods:
        if mspec.type_name not in type_objs:
            raise ValueError(
                f"host seed: SEED_TYPE_METHOD references unknown type "
                f"{mspec.type_name!r}"
            )

    for spec in seeds.instances:
        if spec.type_name is not None:
            typ = type_objs.get(spec.type_name)
            if typ is None:
                raise ValueError(
                    f"host seed instance {spec.name!r} references unknown "
                    f"type {spec.type_name!r}"
                )
            obj = typ()
        else:
            obj = types.SimpleNamespace()
        for name, val in spec.attrs:
            setattr(obj, name, val)
        namespace[spec.name] = obj

    fn = namespace.get(entry)
    if not callable(fn):
        raise ValueError(f"Entry function {entry!r} not found in {source}")
    result = fn()
    if not isinstance(result, (bool, int)):
        raise ValueError(
            f"Entry function {entry!r} returned {type(result).__name__}; "
            "run_image_test expects int or bool results"
        )
    return result


def expected_tag_value(value: int | bool) -> tuple[int, int]:
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    return TAG_INT, int(value) & VAL_MASK


def run_image_test(
    *,
    source: pathlib.Path,
    entry: str,
    program_hex: pathlib.Path,
    dmem_hex: pathlib.Path,
    string_hex: pathlib.Path,
    meta: pathlib.Path,
) -> tuple[int, int]:
    require_python_3_14()
    source = pathlib.Path(source)
    expected = host_entry_result(source, entry)
    expected_tag, expected_value = expected_tag_value(expected)
    image = build_image_from_source_text(source.read_text(encoding="utf-8"), str(source))
    write_image_outputs(
        image,
        program_hex=program_hex,
        dmem_hex=dmem_hex,
        string_hex=string_hex,
        meta=meta,
        expected_tag=expected_tag,
        expected_value=expected_value,
    )
    return expected_tag, expected_value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--entry", default="managed_entry")
    parser.add_argument("--program-hex", default="pycore/programs/program.hex")
    parser.add_argument("--dmem-hex", default="pycore/programs/dmem.hex")
    parser.add_argument("--string-hex", default="pycore/programs/string_mem.hex")
    parser.add_argument("--meta", default="pycore/programs/image.meta")
    args = parser.parse_args()

    run_image_test(
        source=pathlib.Path(args.source),
        entry=args.entry,
        program_hex=pathlib.Path(args.program_hex),
        dmem_hex=pathlib.Path(args.dmem_hex),
        string_hex=pathlib.Path(args.string_hex),
        meta=pathlib.Path(args.meta),
    )


if __name__ == "__main__":
    main()
