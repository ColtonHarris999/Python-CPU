"""Build mpycore/targets/mpycore.json from the pinned MicroPython headers.

Opcode numbers, object-word masks, and the .mpy version come from the
submodule. Phase numbers are the v1 plan's family split: phase 2 is the
integer core, 3 is containers, 4 is exceptions, classes, import, and with,
and 6 is anything still unscheduled.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "vendor" / "micropython"
CATALOG_PATH = ROOT / "mpycore" / "targets" / "mpycore.json"

# name -> (phase, family, operand)
# operand is none, uint, svarint, qstr, slabel, ulabel, slabel_byte, uint_byte, multi
OPCODES = {
    "MP_BC_LOAD_CONST_FALSE": (2, "load_const", "none"),
    "MP_BC_LOAD_CONST_NONE": (2, "load_const", "none"),
    "MP_BC_LOAD_CONST_TRUE": (2, "load_const", "none"),
    "MP_BC_LOAD_CONST_SMALL_INT": (2, "load_const", "svarint"),
    "MP_BC_LOAD_CONST_STRING": (3, "load_const", "qstr"),
    "MP_BC_LOAD_CONST_OBJ": (3, "load_const", "uint"),
    "MP_BC_LOAD_NULL": (2, "load_const", "none"),
    "MP_BC_LOAD_FAST_N": (2, "load_local", "uint"),
    "MP_BC_LOAD_DEREF": (6, "closure", "uint"),
    "MP_BC_LOAD_NAME": (2, "load_global", "qstr"),
    "MP_BC_LOAD_GLOBAL": (2, "load_global", "qstr"),
    "MP_BC_LOAD_ATTR": (4, "attribute", "qstr"),
    "MP_BC_LOAD_METHOD": (4, "call", "qstr"),
    "MP_BC_LOAD_SUPER_METHOD": (4, "call", "qstr"),
    "MP_BC_LOAD_BUILD_CLASS": (4, "class", "none"),
    "MP_BC_LOAD_SUBSCR": (3, "container", "none"),
    "MP_BC_STORE_FAST_N": (2, "store_local", "uint"),
    "MP_BC_STORE_DEREF": (6, "closure", "uint"),
    "MP_BC_STORE_NAME": (2, "store_global", "qstr"),
    "MP_BC_STORE_GLOBAL": (2, "store_global", "qstr"),
    "MP_BC_STORE_ATTR": (4, "attribute", "qstr"),
    "MP_BC_STORE_SUBSCR": (3, "container", "none"),
    "MP_BC_DELETE_FAST": (6, "delete", "uint"),
    "MP_BC_DELETE_DEREF": (6, "closure", "uint"),
    "MP_BC_DELETE_NAME": (6, "delete", "qstr"),
    "MP_BC_DELETE_GLOBAL": (6, "delete", "qstr"),
    "MP_BC_DUP_TOP": (2, "stack", "none"),
    "MP_BC_DUP_TOP_TWO": (2, "stack", "none"),
    "MP_BC_POP_TOP": (2, "stack", "none"),
    "MP_BC_ROT_TWO": (2, "stack", "none"),
    "MP_BC_ROT_THREE": (2, "stack", "none"),
    "MP_BC_UNWIND_JUMP": (4, "exception", "slabel_byte"),
    "MP_BC_JUMP": (2, "jump", "slabel"),
    "MP_BC_POP_JUMP_IF_TRUE": (2, "jump", "slabel"),
    "MP_BC_POP_JUMP_IF_FALSE": (2, "jump", "slabel"),
    "MP_BC_JUMP_IF_TRUE_OR_POP": (2, "jump", "ulabel"),
    "MP_BC_JUMP_IF_FALSE_OR_POP": (2, "jump", "ulabel"),
    "MP_BC_SETUP_WITH": (4, "with", "ulabel"),
    "MP_BC_SETUP_EXCEPT": (4, "exception", "ulabel"),
    "MP_BC_SETUP_FINALLY": (4, "exception", "ulabel"),
    "MP_BC_POP_EXCEPT_JUMP": (4, "exception", "ulabel"),
    "MP_BC_FOR_ITER": (3, "iterate", "ulabel"),
    "MP_BC_WITH_CLEANUP": (4, "with", "none"),
    "MP_BC_END_FINALLY": (4, "exception", "none"),
    "MP_BC_GET_ITER": (3, "iterate", "none"),
    "MP_BC_GET_ITER_STACK": (6, "iterate", "none"),
    "MP_BC_BUILD_TUPLE": (3, "container", "uint"),
    "MP_BC_BUILD_LIST": (3, "container", "uint"),
    "MP_BC_BUILD_MAP": (3, "container", "uint"),
    "MP_BC_STORE_MAP": (3, "container", "none"),
    "MP_BC_BUILD_SET": (3, "container", "uint"),
    "MP_BC_BUILD_SLICE": (6, "container", "uint"),
    "MP_BC_STORE_COMP": (6, "container", "uint"),
    "MP_BC_UNPACK_SEQUENCE": (3, "container", "uint"),
    "MP_BC_UNPACK_EX": (6, "container", "uint"),
    "MP_BC_RETURN_VALUE": (2, "return", "none"),
    "MP_BC_RAISE_LAST": (4, "exception", "none"),
    "MP_BC_RAISE_OBJ": (4, "exception", "none"),
    "MP_BC_RAISE_FROM": (4, "exception", "none"),
    "MP_BC_YIELD_VALUE": (6, "yield", "none"),
    "MP_BC_YIELD_FROM": (6, "yield", "none"),
    "MP_BC_MAKE_FUNCTION": (2, "call", "uint"),
    "MP_BC_MAKE_FUNCTION_DEFARGS": (4, "call", "uint"),
    "MP_BC_MAKE_CLOSURE": (6, "closure", "uint_byte"),
    "MP_BC_MAKE_CLOSURE_DEFARGS": (6, "closure", "uint_byte"),
    "MP_BC_CALL_FUNCTION": (2, "call", "uint"),
    "MP_BC_CALL_FUNCTION_VAR_KW": (6, "call", "uint"),
    "MP_BC_CALL_METHOD": (4, "call", "uint"),
    "MP_BC_CALL_METHOD_VAR_KW": (6, "call", "uint"),
    "MP_BC_IMPORT_NAME": (4, "import", "qstr"),
    "MP_BC_IMPORT_FROM": (4, "import", "qstr"),
    "MP_BC_IMPORT_STAR": (4, "import", "none"),
}

RANGES = {
    "MP_BC_LOAD_CONST_SMALL_INT_MULTI": (2, "load_const"),
    "MP_BC_LOAD_FAST_MULTI": (2, "load_local"),
    "MP_BC_STORE_FAST_MULTI": (2, "store_local"),
    "MP_BC_UNARY_OP_MULTI": (2, "unary"),
    "MP_BC_BINARY_OP_MULTI": (2, "binary"),
}

PHASE2_BINARY = {
    "LESS", "MORE", "EQUAL", "LESS_EQUAL", "MORE_EQUAL", "NOT_EQUAL", "IS",
    "OR", "XOR", "AND", "LSHIFT", "RSHIFT", "ADD", "SUBTRACT", "MULTIPLY",
    "FLOOR_DIVIDE", "MODULO",
}
PHASE4_BINARY = {"IN", "EXCEPTION_MATCH"}

_TOKEN = re.compile(r"\s+|(?:0x[0-9a-fA-F]+|\d+)|[A-Za-z_][A-Za-z0-9_]*|<<|>>|[()|&+]")


def submodule_commit() -> str:
    git_path = VENDOR / ".git"
    text = git_path.read_text().strip()
    if text.startswith("gitdir:"):
        gitdir = (git_path.parent / text.split(":", 1)[1].strip()).resolve()
    else:
        gitdir = git_path
    head = (gitdir / "HEAD").read_text().strip()
    if head.startswith("ref:"):
        ref = head.split(":", 1)[1].strip()
        head = (gitdir / ref).read_text().strip()
    return head


def _read(rel: str) -> str:
    return (VENDOR / rel).read_text()


def _defines(text: str) -> dict[str, str]:
    found = {}
    for match in re.finditer(r"^#define[ \t]+([A-Za-z0-9_]+)[ \t]+(\([^)\n]*\)|\S+)", text, re.M):
        name, expr = match.group(1), match.group(2).strip()
        if expr.startswith("(") and name not in found:
            found[name] = expr
        elif not expr.startswith("("):
            found[name] = expr
    return found


def _eval_expr(expr: str, env: dict[str, int]) -> int:
    tokens = [tok for tok in _TOKEN.findall(expr) if not tok.isspace()]
    pos = 0

    def parse_or():
        nonlocal pos
        value = parse_and()
        while pos < len(tokens) and tokens[pos] == "|":
            pos += 1
            value |= parse_and()
        return value

    def parse_and():
        nonlocal pos
        value = parse_shift()
        while pos < len(tokens) and tokens[pos] == "&":
            pos += 1
            value &= parse_shift()
        return value

    def parse_shift():
        nonlocal pos
        value = parse_add()
        while pos < len(tokens) and tokens[pos] in {"<<", ">>"}:
            op = tokens[pos]
            pos += 1
            rhs = parse_add()
            value = value << rhs if op == "<<" else value >> rhs
        return value

    def parse_add():
        nonlocal pos
        value = parse_primary()
        while pos < len(tokens) and tokens[pos] == "+":
            pos += 1
            value += parse_primary()
        return value

    def parse_primary():
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "(":
            value = parse_or()
            if pos >= len(tokens) or tokens[pos] != ")":
                raise ValueError(f"unbalanced expr {expr}")
            pos += 1
            return value
        if tok in env:
            return env[tok]
        return int(tok, 0)

    value = parse_or()
    if pos != len(tokens):
        raise ValueError(f"cannot evaluate {expr!r} at {tokens[pos:]}")
    return value


def _resolve(defines: dict[str, str], env: dict[str, int]) -> None:
    pending = dict(defines)
    for _ in range(len(pending) + 1):
        progress = False
        for name, expr in list(pending.items()):
            try:
                env[name] = _eval_expr(expr, env)
            except (ValueError, KeyError):
                continue
            pending.pop(name)
            progress = True
        if not pending or not progress:
            break


def _enum_values(text: str, type_name: str, stop_name: str | None = None) -> dict[str, int]:
    marker = f"}} {type_name};"
    end = text.find(marker)
    if end < 0:
        raise ValueError(f"missing enum {type_name}")
    start = text.rindex("typedef enum {", 0, end) + len("typedef enum {")
    body = "\n".join(line.split("//", 1)[0] for line in text[start:end].splitlines())
    values = {}
    current = 0
    for raw in body.split(","):
        name = raw.strip()
        if not name:
            continue
        name = name.split("=", 1)[0].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ValueError(f"bad enum member {name!r} in {type_name}")
        values[name] = current
        current += 1
        if name == stop_name:
            break
    return values


def _persistent_types(text: str) -> dict[str, int]:
    match = re.search(r"enum \{\s*(MP_PERSISTENT_OBJ_.*?)\};", text, re.S)
    if not match:
        raise ValueError("missing persistent object enum")
    values = {}
    current = 0
    for raw in match.group(1).split(","):
        name = raw.split("//", 1)[0].strip()
        name = name.split("=", 1)[0].strip()
        if name:
            values[name] = current
            current += 1
    return values


def _repr_a(text: str) -> dict:
    start = text.index("#if MICROPY_OBJ_REPR == MICROPY_OBJ_REPR_A")
    end = text.index("#elif MICROPY_OBJ_REPR == MICROPY_OBJ_REPR_B", start)
    block = text[start:end]
    small = re.search(
        r"MP_OBJ_NEW_SMALL_INT\(small_int\) \(\(mp_obj_t\)\(\(\(\(mp_uint_t\)\(small_int\)\) << (\d+)\) \| (\d+)\)\)",
        block,
    )
    qstr = re.search(
        r"MP_OBJ_NEW_QSTR\(qst\) \(\(mp_obj_t\)\(\(\(\(mp_uint_t\)\(qst\)\) << (\d+)\) \| (\d+)\)\)",
        block,
    )
    immediate = re.search(
        r"MP_OBJ_NEW_IMMEDIATE_OBJ\(val\) \(\(mp_obj_t\)\(\(\(val\) << (\d+)\) \| (\d+)\)\)",
        block,
    )
    if not (small and qstr and immediate):
        raise ValueError("repr A masks not found in py/obj.h")
    if "(((mp_int_t)(o)) & 1) != 0" not in block:
        raise ValueError("repr A small-int test changed")
    if "(((mp_int_t)(o)) & 7) == 2" not in block:
        raise ValueError("repr A qstr test changed")
    if "(((mp_int_t)(o)) & 7) == 6" not in block:
        raise ValueError("repr A immediate test changed")
    if "(((mp_int_t)(o)) & 3) == 0" not in block:
        raise ValueError("repr A object-pointer test changed")
    return {
        "width": 32,
        "repr": "A",
        "small_int": {"tag_mask": 1, "tag": 1, "shift": int(small.group(1)), "or": int(small.group(2))},
        "qstr": {"tag_mask": 7, "tag": 2, "shift": int(qstr.group(1)), "or": int(qstr.group(2))},
        "immediate": {
            "tag_mask": 7,
            "tag": 6,
            "shift": int(immediate.group(1)),
            "or": int(immediate.group(2)),
        },
        "obj": {"tag_mask": 3, "tag": 0},
    }


def _sentinels(text: str) -> dict[str, int]:
    start = text.index("#else\n#define MP_OBJ_NULL")
    end = text.index("#endif", start)
    block = text[start:end]
    found = {}
    for name in ("MP_OBJ_NULL", "MP_OBJ_STOP_ITERATION", "MP_OBJ_SENTINEL"):
        match = re.search(rf"#define {name}\s+\(MP_OBJ_FROM_PTR\(\(void \*\)(\d+)\)\)", block)
        if not match:
            raise ValueError(f"missing non-debug {name}")
        found[name.removeprefix("MP_OBJ_").lower()] = int(match.group(1))
    return found


def _immediates(text: str) -> dict[str, int]:
    start = text.index("// None is even while False/True are odd")
    end = text.index("#else", start)
    block = text[start:end]
    found = {}
    for name in ("none", "false", "true"):
        match = re.search(rf"#define mp_const_{name} MP_OBJ_NEW_IMMEDIATE_OBJ\((\d+)\)", block)
        if not match:
            raise ValueError(f"missing mp_const_{name}")
        found[name] = int(match.group(1))
    return found


def _version_tuple(text: str) -> tuple[int, int, int]:
    parts = []
    for name in ("MAJOR", "MINOR", "MICRO"):
        match = re.search(rf"#define MICROPY_VERSION_{name} (\d+)", text)
        if not match:
            raise ValueError(f"missing MICROPY_VERSION_{name}")
        parts.append(int(match.group(1)))
    return parts[0], parts[1], parts[2]


def _binary_phase(name: str) -> int:
    short = name.removeprefix("MP_BINARY_OP_")
    if short.startswith("INPLACE_"):
        short = short.removeprefix("INPLACE_")
    if short in PHASE2_BINARY:
        return 2
    if short in PHASE4_BINARY:
        return 4
    return 6


def build_catalog() -> dict:
    bc0 = _read("py/bc0.h")
    runtime0 = _read("py/runtime0.h")
    persistent = _read("py/persistentcode.h")
    obj = _read("py/obj.h")
    mpconfig = _read("py/mpconfig.h")
    bc = _read("py/bc.h")

    env: dict[str, int] = {}
    unary = _enum_values(runtime0, "mp_unary_op_t", "MP_UNARY_OP_NOT")
    binary = _enum_values(runtime0, "mp_binary_op_t", "MP_BINARY_OP_POWER")
    env.update(unary)
    env.update(binary)
    _resolve(_defines(runtime0), env)
    _resolve(_defines(bc0), env)
    _resolve(_defines(persistent), env)

    missing = [name for name in OPCODES if name not in env]
    if missing:
        raise SystemExit(f"header is missing opcodes {missing}")
    extra = sorted(
        name for name in env
        if name.startswith("MP_BC_")
        and name not in OPCODES
        and name not in RANGES
        and not name.startswith("MP_BC_MASK_")
        and not name.startswith("MP_BC_FORMAT")
        and not name.startswith("MP_BC_BASE_")
        and not name.endswith("_NUM")
        and not name.endswith("_EXCESS")
    )
    if extra:
        raise SystemExit(f"classify new opcodes {extra}")

    major, minor, micro = _version_tuple(mpconfig)
    for field in ("n_state", "n_exc_stack", "scope_flags", "n_pos_args", "n_kwonly_args", "n_def_pos_args", "n_info", "n_cell"):
        if field not in bc:
            raise SystemExit(f"prelude field {field} missing from py/bc.h")

    scope_flags = {
        name: env[name]
        for name in (
            "MP_SCOPE_FLAG_ALL_SIG",
            "MP_SCOPE_FLAG_GENERATOR",
            "MP_SCOPE_FLAG_VARKEYWORDS",
            "MP_SCOPE_FLAG_VARARGS",
            "MP_SCOPE_FLAG_DEFKWARGS",
        )
    }

    opcodes = []
    for name, (phase, family, operand) in OPCODES.items():
        opcodes.append({
            "name": name,
            "value": env[name],
            "phase": phase,
            "family": family,
            "operand": operand,
        })
    opcodes.sort(key=lambda item: item["value"])

    ranges = []
    for name, (phase, family) in RANGES.items():
        count_name = name + "_NUM"
        entry = {
            "name": name,
            "base": env[name],
            "count": env[count_name],
            "phase": phase,
            "family": family,
        }
        if name == "MP_BC_LOAD_CONST_SMALL_INT_MULTI":
            entry["excess"] = env["MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS"]
        ranges.append(entry)

    return {
        "name": "mpycore",
        "micropython": {
            "tag": f"v{major}.{minor}.{micro}",
            "commit": submodule_commit(),
            "version": [major, minor, micro],
            "mpy_version": env["MPY_VERSION"],
            "mpy_sub_version": env["MPY_SUB_VERSION"],
            "small_int_bits": 31,
            "obj_repr": "A",
        },
        "sources": [
            "py/bc0.h",
            "py/bc.h",
            "py/obj.h",
            "py/persistentcode.h",
            "py/runtime0.h",
            "py/mpconfig.h",
        ],
        "object_word": _repr_a(obj),
        "sentinels": _sentinels(obj),
        "immediates": _immediates(obj),
        "scope_flags": scope_flags,
        "prelude_fields": [
            "n_state",
            "n_exc_stack",
            "scope_flags",
            "n_pos_args",
            "n_kwonly_args",
            "n_def_pos_args",
            "n_info",
            "n_cells",
        ],
        "persistent_obj": _persistent_types(persistent),
        "unary_ops": [
            {"name": name, "value": value, "phase": 2}
            for name, value in unary.items()
        ],
        "binary_ops": [
            {"name": name, "value": value, "phase": _binary_phase(name)}
            for name, value in binary.items()
        ],
        "opcodes": opcodes,
        "opcode_ranges": ranges,
    }


def main() -> None:
    catalog = build_catalog()
    CATALOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CATALOG_PATH.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"wrote {CATALOG_PATH} ({catalog['micropython']['tag']})")


if __name__ == "__main__":
    main()
