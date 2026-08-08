#!/usr/bin/env python3.14
"""Build the synthetic §6.1 container↔CALL pause/resume image."""

from __future__ import annotations

import argparse
import dis
import opcode
import pathlib
import types

from encoding import TAG_INT
from image_from_source import build_image_from_code, write_image_outputs


def _rewrite_managed_entry(code: types.CodeType) -> types.CodeType:
    consts: list[object] = []
    for const in code.co_consts:
        if not isinstance(const, types.CodeType):
            consts.append(const)
            continue
        if const.co_name != "managed_entry":
            consts.append(const)
            continue

        calls = [
            instruction
            for instruction in dis.get_instructions(const)
            if instruction.opname == "CALL"
        ]
        if len(calls) != 2 or calls[0].arg != 0 or calls[1].arg != 1:
            raise ValueError(
                "spike fixture expects managed_entry CALL 0 followed by CALL 1"
            )
        rewritten = bytearray(const.co_code)
        rewritten[calls[0].offset] = opcode.opmap["GET_ITER"]
        rewritten[calls[0].offset + 1] = 0
        consts.append(const.replace(co_code=bytes(rewritten)))

    if not any(
        isinstance(const, types.CodeType) and const.co_name == "managed_entry"
        for const in consts
    ):
        raise ValueError("managed_entry code object not found")
    return code.replace(co_consts=tuple(consts))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--program-hex", required=True, type=pathlib.Path)
    parser.add_argument("--dmem-hex", required=True, type=pathlib.Path)
    parser.add_argument("--string-hex", required=True, type=pathlib.Path)
    parser.add_argument("--meta", required=True, type=pathlib.Path)
    args = parser.parse_args()

    source_text = args.source.read_text(encoding="utf-8")
    module_code = compile(source_text, str(args.source), "exec")
    module_code = _rewrite_managed_entry(module_code)
    result = build_image_from_code(module_code)
    write_image_outputs(
        result,
        program_hex=args.program_hex,
        dmem_hex=args.dmem_hex,
        string_hex=args.string_hex,
        meta=args.meta,
        expected_tag=TAG_INT,
        expected_value=3,
    )


if __name__ == "__main__":
    main()
