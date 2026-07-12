#!/usr/bin/env python3.14
"""Generate a PyCore image and expected result from a Python source module."""

from __future__ import annotations

import argparse
import pathlib

from encoding import TAG_BOOL, TAG_INT, VAL_MASK
from image_from_source import (
    build_image_from_source_text,
    require_python_3_14,
    write_image_outputs,
)


def host_entry_result(source: pathlib.Path, entry: str) -> int | bool:
    source = pathlib.Path(source)
    source_text = source.read_text(encoding="utf-8")
    namespace: dict[str, object] = {"__name__": "__pycore_host__"}
    exec(compile(source_text, str(source), "exec"), namespace)
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
