"""Read a pinned-toolchain .mpy file and lay it out as an mpycore flash image.

The image is what the microcontroller hart will execute in place: a qstr
pool, a const pool, and the raw bytecode bytes with their preludes. It is
not a CPython code object.
"""

from __future__ import annotations

import json
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "mpycore" / "targets" / "mpycore.json"
MPY_CROSS = ROOT / "build" / "mpy-cross" / "mpy-cross"

MAGIC = b"MPYC"
IMAGE_VERSION = 1
HEADER = struct.Struct("<4s8I")


class MpyError(ValueError):
    pass


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text())


def compile_file(source: Path, output: Path) -> None:
    if not MPY_CROSS.is_file():
        raise MpyError(f"build mpy-cross first: {MPY_CROSS}")
    catalog = load_catalog()
    subprocess.check_call(
        [
            str(MPY_CROSS),
            f"-msmall-int-bits={catalog['micropython']['small_int_bits']}",
            "-o",
            str(output),
            str(source),
        ],
        stdout=subprocess.DEVNULL,
    )


def _uint(data: bytes, pos: int) -> tuple[int, int]:
    number = 0
    while True:
        if pos >= len(data):
            raise MpyError("truncated varint")
        byte = data[pos]
        pos += 1
        number = (number << 7) | (byte & 0x7f)
        if (byte & 0x80) == 0:
            return number, pos


def _slabel(data: bytes, pos: int) -> tuple[int, int]:
    if data[pos] & 0x80:
        return ((data[pos] & 0x7f) | (data[pos + 1] << 7)) - 0x4000, pos + 2
    return data[pos] - 0x40, pos + 1


def _ulabel(data: bytes, pos: int) -> tuple[int, int]:
    if data[pos] & 0x80:
        return (data[pos] & 0x7f) | (data[pos + 1] << 7), pos + 2
    return data[pos], pos + 1


def _svarint(data: bytes, pos: int) -> tuple[int, int]:
    # Same bit pattern as mp_bytecode_print_str's signed varint.
    number = -1 if data[pos] & 0x40 else 0
    while True:
        byte = data[pos]
        pos += 1
        number = (number << 7) | (byte & 0x7f)
        if (byte & 0x80) == 0:
            return number, pos


def decode_prelude(fun_data: bytes) -> dict:
    """Decode the prelude fields the call path reads. Matches py/bc.h."""
    pos = 0
    z = fun_data[pos]
    pos += 1
    state = (z >> 3) & 0xf
    exc_stack = (z >> 2) & 0x1
    flags = 0
    pos_args = z & 0x3
    kwonly = 0
    def_pos = 0
    extra = 0
    while z & 0x80:
        z = fun_data[pos]
        pos += 1
        state |= (z & 0x30) << (2 * extra)
        exc_stack |= (z & 0x02) << extra
        flags |= ((z & 0x40) >> 6) << extra
        pos_args |= (z & 0x4) << extra
        kwonly |= ((z & 0x08) >> 3) << extra
        def_pos |= (z & 0x1) << extra
        extra += 1
    state += 1

    info_len = 0
    n_cells = 0
    extra = 0
    while True:
        z = fun_data[pos]
        pos += 1
        n_cells |= (z & 1) << extra
        info_len |= ((z & 0x7e) >> 1) << (6 * extra)
        extra += 1
        if (z & 0x80) == 0:
            break
    info = fun_data[pos:pos + info_len]
    if len(info) != info_len:
        raise MpyError("truncated prelude info")
    name_index, name_end = _uint(info, 0)
    opcodes = fun_data[pos + info_len + n_cells:]
    return {
        "n_state": state,
        "n_exc_stack": exc_stack,
        "scope_flags": flags,
        "n_pos_args": pos_args,
        "n_kwonly_args": kwonly,
        "n_def_pos_args": def_pos,
        "n_info": info_len,
        "n_cells": n_cells,
        "simple_name": name_index,
        "info_end": name_end,
        "opcodes": opcodes,
    }


class _Cursor:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def byte(self) -> int:
        if self.pos >= len(self.data):
            raise MpyError("truncated .mpy")
        value = self.data[self.pos]
        self.pos += 1
        return value

    def uint(self) -> int:
        value, self.pos = _uint(self.data, self.pos)
        return value

    def bytes(self, count: int) -> bytes:
        end = self.pos + count
        if end > len(self.data):
            raise MpyError("truncated .mpy")
        blob = self.data[self.pos:end]
        self.pos = end
        return blob


def _load_qstr(cursor: _Cursor) -> dict:
    length = cursor.uint()
    if length & 1:
        return {"static": length >> 1}
    length >>= 1
    text = cursor.bytes(length)
    if cursor.byte() != 0:
        raise MpyError("qstr missing NUL")
    return {"text": text.decode("utf-8")}


def _load_obj(cursor: _Cursor) -> dict:
    kind = cursor.byte()
    names = {value: name for name, value in load_catalog()["persistent_obj"].items()}
    name = names.get(kind)
    if name in {"MP_PERSISTENT_OBJ_NONE", "MP_PERSISTENT_OBJ_FALSE", "MP_PERSISTENT_OBJ_TRUE", "MP_PERSISTENT_OBJ_ELLIPSIS", "MP_PERSISTENT_OBJ_FUN_TABLE"}:
        return {"kind": name}
    if name == "MP_PERSISTENT_OBJ_TUPLE":
        count = cursor.uint()
        return {"kind": name, "items": [_load_obj(cursor) for _ in range(count)]}
    if name in {"MP_PERSISTENT_OBJ_STR", "MP_PERSISTENT_OBJ_BYTES", "MP_PERSISTENT_OBJ_INT", "MP_PERSISTENT_OBJ_FLOAT", "MP_PERSISTENT_OBJ_COMPLEX"}:
        length = cursor.uint()
        payload = cursor.bytes(length)
        if name in {"MP_PERSISTENT_OBJ_STR", "MP_PERSISTENT_OBJ_BYTES"}:
            if cursor.byte() != 0:
                raise MpyError("const string missing NUL")
        return {"kind": name, "data": payload.decode("utf-8")}
    raise MpyError(f"unknown const kind {kind}")


def _load_raw(cursor: _Cursor) -> dict:
    kind_len = cursor.uint()
    kind = kind_len & 3
    has_children = bool(kind_len & 4)
    fun_len = kind_len >> 3
    if kind != 0:
        raise MpyError("native code in .mpy is not an mpycore image")
    fun_data = cursor.bytes(fun_len)
    children = []
    if has_children:
        count = cursor.uint()
        children = [_load_raw(cursor) for _ in range(count)]
    prelude = decode_prelude(fun_data)
    return {"fun_data": fun_data, "prelude": prelude, "children": children}


def load_mpy(data: bytes) -> dict:
    catalog = load_catalog()
    pinned = catalog["micropython"]
    cursor = _Cursor(data)
    header = cursor.bytes(4)
    if header[0:1] != b"M" or header[1] != pinned["mpy_version"]:
        raise MpyError(f"incompatible .mpy header {header.hex()}")
    if header[2] != 0:
        raise MpyError("native architecture in .mpy")
    if header[3] != pinned["small_int_bits"]:
        raise MpyError(f"small-int width {header[3]} is not {pinned['small_int_bits']}")
    n_qstr = cursor.uint()
    n_obj = cursor.uint()
    qstrs = [_load_qstr(cursor) for _ in range(n_qstr)]
    consts = [_load_obj(cursor) for _ in range(n_obj)]
    raw = _load_raw(cursor)
    if cursor.pos != len(data):
        raise MpyError(f"trailing bytes at {cursor.pos}")
    return {"qstrs": qstrs, "consts": consts, "raw": raw}


def qstr_name(pool: list[dict], index: int) -> str:
    entry = pool[index]
    if "text" in entry:
        return entry["text"]
    return f"<static:{entry['static']}>"


def disassemble(raw: dict, catalog: dict | None = None) -> list[dict]:
    catalog = catalog or load_catalog()
    by_value = {op["value"]: op for op in catalog["opcodes"]}
    ranges = {item["name"]: item for item in catalog["opcode_ranges"]}
    unary = {op["value"]: op["name"] for op in catalog["unary_ops"]}
    binary = {op["value"]: op["name"] for op in catalog["binary_ops"]}
    data = raw["prelude"]["opcodes"]
    pos = 0
    instructions = []
    while pos < len(data):
        opcode = data[pos]
        pos += 1
        small = ranges["MP_BC_LOAD_CONST_SMALL_INT_MULTI"]
        fast = ranges["MP_BC_LOAD_FAST_MULTI"]
        store = ranges["MP_BC_STORE_FAST_MULTI"]
        unop = ranges["MP_BC_UNARY_OP_MULTI"]
        binop = ranges["MP_BC_BINARY_OP_MULTI"]
        if small["base"] <= opcode < small["base"] + small["count"]:
            instructions.append({
                "op": "MP_BC_LOAD_CONST_SMALL_INT",
                "arg": opcode - small["base"] - small["excess"],
            })
            continue
        if fast["base"] <= opcode < fast["base"] + fast["count"]:
            instructions.append({"op": "MP_BC_LOAD_FAST", "arg": opcode - fast["base"]})
            continue
        if store["base"] <= opcode < store["base"] + store["count"]:
            instructions.append({"op": "MP_BC_STORE_FAST", "arg": opcode - store["base"]})
            continue
        if unop["base"] <= opcode < unop["base"] + unop["count"]:
            index = opcode - unop["base"]
            instructions.append({"op": "MP_BC_UNARY_OP", "arg": index, "name": unary[index]})
            continue
        if binop["base"] <= opcode < binop["base"] + binop["count"]:
            index = opcode - binop["base"]
            instructions.append({"op": "MP_BC_BINARY_OP", "arg": index, "name": binary[index]})
            continue
        spec = by_value.get(opcode)
        if spec is None:
            raise MpyError(f"unknown opcode 0x{opcode:02x}")
        operand = spec["operand"]
        arg = None
        if operand == "uint" or operand == "qstr":
            arg, pos = _uint(data, pos)
        elif operand == "svarint":
            arg, pos = _svarint(data, pos)
        elif operand == "slabel":
            arg, pos = _slabel(data, pos)
        elif operand == "ulabel":
            arg, pos = _ulabel(data, pos)
        elif operand == "slabel_byte":
            arg, pos = _slabel(data, pos)
            extra = data[pos]
            pos += 1
            arg = (arg, extra)
        elif operand == "uint_byte":
            arg, pos = _uint(data, pos)
            extra = data[pos]
            pos += 1
            arg = (arg, extra)
        elif operand != "none":
            raise MpyError(f"bad operand {operand}")
        instructions.append({"op": spec["name"], "arg": arg})
    return instructions


def object_word(value: int, kind: str, catalog: dict | None = None) -> int:
    catalog = catalog or load_catalog()
    word = catalog["object_word"]
    if kind == "small_int":
        spec = word["small_int"]
        return ((value << spec["shift"]) | spec["or"]) & 0xFFFFFFFF
    if kind == "immediate":
        spec = word["immediate"]
        return ((value << spec["shift"]) | spec["or"]) & 0xFFFFFFFF
    raise MpyError(kind)


def const_word(const: dict, catalog: dict | None = None) -> int | None:
    """Object word for an immediate or a small int. Other consts stay in the side pool."""
    catalog = catalog or load_catalog()
    immediates = catalog["immediates"]
    kind = const["kind"]
    if kind == "MP_PERSISTENT_OBJ_NONE":
        return object_word(immediates["none"], "immediate", catalog)
    if kind == "MP_PERSISTENT_OBJ_FALSE":
        return object_word(immediates["false"], "immediate", catalog)
    if kind == "MP_PERSISTENT_OBJ_TRUE":
        return object_word(immediates["true"], "immediate", catalog)
    if kind == "MP_PERSISTENT_OBJ_INT":
        text = const["data"]
        if text.startswith("-"):
            number = -int(text[1:], 10)
        else:
            number = int(text, 10)
        limit = 1 << (catalog["micropython"]["small_int_bits"] - 1)
        if -limit <= number < limit:
            return object_word(number, "small_int", catalog)
    return None


def _pack_qstrs(qstrs: list[dict]) -> bytes:
    out = bytearray()
    out += struct.pack("<I", len(qstrs))
    for entry in qstrs:
        if "text" in entry:
            blob = entry["text"].encode("utf-8")
            out += struct.pack("<BI", 1, len(blob))
            out += blob
        else:
            out += struct.pack("<BI", 2, entry["static"])
    return bytes(out)


def _pack_consts(consts: list[dict], catalog: dict) -> bytes:
    out = bytearray()
    out += struct.pack("<I", len(consts))
    for const in consts:
        word = const_word(const, catalog)
        if word is not None:
            out += struct.pack("<BI", 1, word)
        else:
            payload = json.dumps(const).encode("utf-8")
            out += struct.pack("<BI", 2, len(payload))
            out += payload
    return bytes(out)


def _functions(raw: dict) -> tuple[list[dict], list[list[int]]]:
    funcs: list[dict] = []
    child_lists: list[list[int]] = []

    def walk(node: dict) -> int:
        index = len(funcs)
        funcs.append(node)
        child_lists.append([])
        for child in node["children"]:
            child_lists[index].append(walk(child))
        return index

    walk(raw)
    return funcs, child_lists


def layout_flash(module: dict, catalog: dict | None = None) -> bytes:
    catalog = catalog or load_catalog()
    qstr_blob = _pack_qstrs(module["qstrs"])
    const_blob = _pack_consts(module["consts"], catalog)
    functions, child_lists = _functions(module["raw"])
    entries = []
    cursor = 0
    for func, children in zip(functions, child_lists):
        entries.append((cursor, func["fun_data"], children))
        cursor += len(func["fun_data"])
    dir_size = 4 + sum(12 + 4 * len(children) for _, _, children in entries)
    directory = bytearray(struct.pack("<I", len(functions)))
    for offset, fun_data, children in entries:
        directory += struct.pack("<III", dir_size + offset, len(fun_data), len(children))
        if children:
            directory += struct.pack("<" + "I" * len(children), *children)
    code_blob = bytes(directory) + b"".join(fun_data for _, fun_data, _ in entries)
    if len(code_blob) != dir_size + cursor:
        raise MpyError("flash code directory size mismatch")

    header_size = HEADER.size
    qstr_off = header_size
    const_off = qstr_off + len(qstr_blob)
    code_off = const_off + len(const_blob)
    pinned = catalog["micropython"]
    header = HEADER.pack(
        MAGIC,
        IMAGE_VERSION,
        pinned["mpy_version"],
        pinned["small_int_bits"],
        len(module["qstrs"]),
        len(module["consts"]),
        qstr_off,
        const_off,
        code_off,
    )
    return header + qstr_blob + const_blob + code_blob


def parse_flash(image: bytes) -> dict:
    if len(image) < HEADER.size:
        raise MpyError("short flash image")
    magic, version, mpy_version, small_bits, n_qstr, n_const, qstr_off, const_off, code_off = HEADER.unpack_from(image)
    if magic != MAGIC or version != IMAGE_VERSION:
        raise MpyError("bad flash magic")
    pos = qstr_off
    count = struct.unpack_from("<I", image, pos)[0]
    pos += 4
    qstrs = []
    for _ in range(count):
        kind, value = struct.unpack_from("<BI", image, pos)
        pos += 5
        if kind == 1:
            qstrs.append({"text": image[pos:pos + value].decode("utf-8")})
            pos += value
        elif kind == 2:
            qstrs.append({"static": value})
        else:
            raise MpyError("bad qstr kind")
    if count != n_qstr:
        raise MpyError("qstr count mismatch")
    pos = const_off
    count = struct.unpack_from("<I", image, pos)[0]
    pos += 4
    consts = []
    for _ in range(count):
        kind, value = struct.unpack_from("<BI", image, pos)
        pos += 5
        if kind == 1:
            consts.append({"word": value})
        elif kind == 2:
            consts.append(json.loads(image[pos:pos + value].decode("utf-8")))
            pos += value
        else:
            raise MpyError("bad const kind")
    if count != n_const:
        raise MpyError("const count mismatch")
    pos = code_off
    n_funcs = struct.unpack_from("<I", image, pos)[0]
    pos += 4
    functions = []
    for _ in range(n_funcs):
        offset, length, n_children = struct.unpack_from("<III", image, pos)
        pos += 12
        children = list(struct.unpack_from("<" + "I" * n_children, image, pos)) if n_children else []
        pos += 4 * n_children
        fun_data = image[code_off + offset:code_off + offset + length]
        functions.append({
            "fun_data": fun_data,
            "children": children,
            "prelude": decode_prelude(fun_data),
        })
    return {
        "mpy_version": mpy_version,
        "small_int_bits": small_bits,
        "qstrs": qstrs,
        "consts": consts,
        "functions": functions,
    }


def format_function(module: dict, raw: dict) -> str:
    prelude = raw["prelude"]
    name = qstr_name(module["qstrs"], prelude["simple_name"])
    lines = [
        f"{name}: n_state={prelude['n_state']} n_exc_stack={prelude['n_exc_stack']} "
        f"n_pos_args={prelude['n_pos_args']} n_def_pos_args={prelude['n_def_pos_args']}"
    ]
    for inst in disassemble(raw):
        if inst["arg"] is None:
            lines.append(f"  {inst['op']}")
        else:
            extra = f" {inst['name']}" if "name" in inst else ""
            lines.append(f"  {inst['op']} {inst['arg']}{extra}")
    for child in raw["children"]:
        lines.append(format_function(module, child))
    return "\n".join(lines)
