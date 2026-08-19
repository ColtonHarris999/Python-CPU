#!/usr/bin/env python3.14
"""Generate a PyCore image and expected result from a Python source module."""

from __future__ import annotations

import argparse
import ast
import pathlib
import re
import types

from encoding import (
    HEAP_LIMIT,
    TAG_BOOL,
    TAG_INT,
    VAL_MASK,
    allocator_list_capacity,
)
from encoding import CODE_RAM_SLOT_BASE
from image_from_source import (
    build_image_from_source_text,
    load_rom_firmware_callables,
    parse_seed_pragmas,
    require_python_3_14,
    write_image_outputs,
)

# `# pycore-inject: HEAP_LIST_CAPACITY CAPACITY` — rewrite module-level CAPACITY
# from the live bump-heap budget after a probe image build.
_HEAP_LIST_CAPACITY_RE = re.compile(
    r"^#\s*pycore-inject:\s*HEAP_LIST_CAPACITY\s+(\w+)\s*$",
    re.MULTILINE,
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


def expected_tag_value(value: int | bool) -> tuple[int, int]:
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    return TAG_INT, int(value) & VAL_MASK


def parse_heap_list_capacity_inject(source_text: str) -> str | None:
    """Return the injected name (e.g. ``CAPACITY``) when the pragma is present."""
    match = _HEAP_LIST_CAPACITY_RE.search(source_text)
    if match is None:
        return None
    return match.group(1)


def rewrite_capacity_assignment(source_text: str, name: str, capacity: int) -> str:
    pattern = re.compile(
        rf"^({re.escape(name)})\s*=\s*\d+\s*(#.*)?$",
        re.MULTILINE,
    )
    rewritten, n = pattern.subn(rf"\1 = {capacity}", source_text, count=1)
    if n != 1:
        raise ValueError(
            f"pycore-inject HEAP_LIST_CAPACITY: expected one assignment "
            f"for {name!r}, found {n}"
        )
    return rewritten


def apply_heap_list_capacity_inject(
    source_text: str,
    *,
    filename: str,
) -> str:
    """Probe-build then rewrite CAPACITY from ``HEAP_LIMIT - HEAP_INIT_PTR``."""
    name = parse_heap_list_capacity_inject(source_text)
    if name is None:
        return source_text
    probe_text = rewrite_capacity_assignment(source_text, name, 32)
    probe = build_image_from_source_text(probe_text, filename)
    available = HEAP_LIMIT - probe.heap_init_ptr
    capacity = allocator_list_capacity(available)
    return rewrite_capacity_assignment(source_text, name, capacity)


def host_entry_result_from_text(
    source_text: str,
    *,
    filename: str,
    entry: str,
) -> int | bool:
    # Optional override when host execution cannot mirror HW semantics
    # (e.g. __iter__ returning a list is legal on PyCore Track A but not
    # on CPython).  Format: `# pycore-expect: <int>`
    for line in source_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("# pycore-expect:"):
            raw = stripped.split(":", 1)[1].strip()
            return int(raw, 0)

    seeds = parse_seed_pragmas(source_text)

    tree = ast.parse(source_text, filename=filename)
    tree = _RemoveEntryCall(entry).visit(tree)
    ast.fix_missing_locations(tree)

    namespace: dict[str, object] = {"__name__": "__pycore_host__"}
    exec(compile(tree, filename, "exec"), namespace)

    # Match HW boot builtins: inject ROM firmware callables so host goldens
    # follow firmware semantics (e.g. reversed/filter return lists).
    for name, fn in load_rom_firmware_callables().items():
        namespace.setdefault(name, fn)

    # exec/eval need host stand-ins: the ROM bodies call the code object, and
    # CPython code objects are not callable. Binding `namespace` as the payload
    # globals reproduces the device, where a module-mode code object's
    # STORE_NAME / LOAD_NAME hit the one boot-record globals dict.
    def _host_exec(code, globals=None):
        exec(code, namespace if globals is None else globals)
        return None

    def _host_eval(code, globals=None):
        return eval(code, namespace if globals is None else globals)

    namespace["exec"] = _host_exec
    namespace["eval"] = _host_eval

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
        bases: tuple[type, ...] = ()
        if spec.base_name is not None:
            base_typ = type_objs.get(spec.base_name)
            if base_typ is None:
                raise ValueError(
                    f"host seed: SEED_TYPE {spec.name!r} base={spec.base_name!r}: "
                    "declare the base SEED_TYPE earlier in the source"
                )
            bases = (base_typ,)
        typ = type(spec.name, bases, body)
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

    # SEED_CODE: mirror the device's precompiled payload with a host code
    # object so exec()/eval() goldens run identically on both sides. The
    # payload must share the entry's globals, since device STORE_NAME writes
    # the one module globals dict.
    for cspec in seeds.codes:
        namespace[cspec.name] = compile(
            cspec.source, f"<seed:{cspec.name}>", cspec.mode
        )

    fn = namespace.get(entry)
    if not callable(fn):
        raise ValueError(f"Entry function {entry!r} not found in {filename}")
    result = fn()
    if not isinstance(result, (bool, int)):
        raise ValueError(
            f"Entry function {entry!r} returned {type(result).__name__}; "
            "run_image_test expects int or bool results"
        )
    return result


def host_entry_result(source: pathlib.Path, entry: str) -> int | bool:
    source = pathlib.Path(source)
    source_text = source.read_text(encoding="utf-8")
    source_text = apply_heap_list_capacity_inject(
        source_text, filename=str(source)
    )
    return host_entry_result_from_text(
        source_text, filename=str(source), entry=entry
    )


def run_image_test(
    *,
    source: pathlib.Path,
    entry: str,
    program_hex: pathlib.Path,
    dmem_hex: pathlib.Path,
    string_hex: pathlib.Path,
    meta: pathlib.Path,
    slot_base: int = 0,
) -> tuple[int, int]:
    require_python_3_14()
    source = pathlib.Path(source)
    source_text = apply_heap_list_capacity_inject(
        source.read_text(encoding="utf-8"),
        filename=str(source),
    )
    expected = host_entry_result_from_text(
        source_text, filename=str(source), entry=entry
    )
    expected_tag, expected_value = expected_tag_value(expected)
    image = build_image_from_source_text(
        source_text, str(source), slot_base=slot_base
    )
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
    parser.add_argument(
        "--code-ram",
        action="store_true",
        help=(
            "Place the program in code RAM: entry slots are offset by "
            "CODE_RAM_SLOT_BASE and --program-hex is meant for CODE_RAM_HEX "
            "(Plan 1 P1)."
        ),
    )
    args = parser.parse_args()

    run_image_test(
        source=pathlib.Path(args.source),
        entry=args.entry,
        program_hex=pathlib.Path(args.program_hex),
        dmem_hex=pathlib.Path(args.dmem_hex),
        string_hex=pathlib.Path(args.string_hex),
        meta=pathlib.Path(args.meta),
        slot_base=CODE_RAM_SLOT_BASE if args.code_ram else 0,
    )


if __name__ == "__main__":
    main()
