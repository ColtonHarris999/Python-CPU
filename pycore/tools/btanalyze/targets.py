"""Target description loading, schema validation, and opcode resolution.

A *target* describes how a particular stack-machine maps CPython 3.14 bytecode
onto hardware. It is two orthogonal taxonomies plus the current support state:

* ``support``  -- what the hardware does *today* (execute/partial/strip/...).
* ``hw_class`` -- the *intrinsic* datapath unit an opcode would need, with a
  ``fit`` tier (native/costly/heavy/infeasible). Independent of ``support``.
* ``fold``     -- the dataflow shape (SRC/UNY/RDX/SNK/BRC/BAR) used by folding.

The file is JSON (stdlib-only). ``.yaml``/``.yml`` is accepted opportunistically
when PyYAML happens to be importable, so YAML stays opt-in without a hard dep.
"""

from __future__ import annotations

import json
import opcode
import pathlib
from dataclasses import dataclass


# --- Intrinsic class membership (a property of CPython 3.14, target-agnostic) -
#
# These sets are the derivation rule the consistency test checks the target
# against: an opcode's hw_class/fold are reproducible from its semantics, not
# hand-waved per target. They are grounded in opcode.{haslocal,...} + role.

REG_OPNAMES = {
    "LOAD_FAST", "LOAD_FAST_BORROW", "LOAD_FAST_CHECK", "LOAD_FAST_AND_CLEAR",
    "LOAD_FAST_LOAD_FAST", "LOAD_FAST_BORROW_LOAD_FAST_BORROW", "STORE_FAST",
    "STORE_FAST_LOAD_FAST", "STORE_FAST_STORE_FAST", "STORE_FAST_MAYBE_NULL",
    "DELETE_FAST", "COPY", "SWAP",
}
IMM_OPNAMES = {"LOAD_SMALL_INT"}
CONST_OPNAMES = {"LOAD_CONST"}
ALU1_OPNAMES = {"UNARY_NEGATIVE", "UNARY_INVERT", "BINARY_OP"}
PRED_OPNAMES = {"COMPARE_OP", "TO_BOOL", "UNARY_NOT"}
BRANCH_OPNAMES = {
    "POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE", "POP_JUMP_IF_NONE",
    "POP_JUMP_IF_NOT_NONE", "JUMP_IF_TRUE", "JUMP_IF_FALSE", "JUMP_FORWARD",
    "JUMP_BACKWARD", "JUMP_BACKWARD_NO_INTERRUPT", "RETURN_VALUE", "RESUME",
    "NOT_TAKEN", "NOP", "POP_TOP", "POP_ITER",
}
FRAME_OPNAMES = {"CALL"}

# Interpreter plumbing: never reaches a hardware target. Computed so the 21
# INSTRUMENTED_* shadow opcodes are always covered regardless of build.
INTERNAL_OPNAMES = {n for n in opcode.opmap if n.startswith("INSTRUMENTED_")} | {
    "CACHE", "RESERVED", "EXTENDED_ARG", "ENTER_EXECUTOR", "INTERPRETER_EXIT",
    "JUMP", "JUMP_NO_INTERRUPT", "ANNOTATIONS_PLACEHOLDER",
}

# fold dataflow-shape membership (the scalar cells of the lattice; rest = BAR).
FOLD_SRC = {
    "LOAD_FAST", "LOAD_FAST_BORROW", "LOAD_FAST_CHECK", "LOAD_FAST_AND_CLEAR",
    "LOAD_SMALL_INT",
    "LOAD_CONST", "COPY", "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
    "LOAD_FAST_LOAD_FAST",
}
FOLD_UNY = {"UNARY_NEGATIVE", "UNARY_INVERT", "UNARY_NOT", "TO_BOOL"}
FOLD_RDX = {"BINARY_OP", "COMPARE_OP"}
FOLD_SNK = {"STORE_FAST", "STORE_FAST_STORE_FAST"}
FOLD_BRC = {"POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE"}


def derive_hw_class(opname: str) -> str:
    """Reproduce an opcode's hw_class from intrinsic membership."""
    if opname in INTERNAL_OPNAMES:
        return "INTERNAL"
    if opname in REG_OPNAMES:
        return "REG"
    if opname in IMM_OPNAMES:
        return "IMM"
    if opname in CONST_OPNAMES:
        return "CONST"
    if opname in ALU1_OPNAMES:
        return "ALU1"
    if opname in PRED_OPNAMES:
        return "PRED"
    if opname in BRANCH_OPNAMES:
        return "BRANCH"
    if opname in FRAME_OPNAMES:
        return "FRAME"
    return "OBJECT"


def derive_fold(opname: str) -> str:
    """Reproduce an opcode's base fold category from its dataflow shape."""
    if opname in FOLD_SRC:
        return "SRC"
    if opname in FOLD_UNY:
        return "UNY"
    if opname in FOLD_RDX:
        return "RDX"
    if opname in FOLD_SNK:
        return "SNK"
    if opname in FOLD_BRC:
        return "BRC"
    return "BAR"


@dataclass(frozen=True)
class OpInfo:
    """Resolved per-instruction view, combining target rows with oparg logic."""

    opname: str
    arg: int | None
    support: str
    hw_class: str
    fit: str
    fold: str  # effective (oparg-gated) fold category
    needs_leaf: str | None
    current_module: str | None
    suppress: bool
    severity: str  # baseline severity from support_levels
    remediation: str
    obj_group: str | None = None
    obj_distance: int | None = None
    needs_subsystem: str | None = None
    message: str | None = None
    suggestion: str | None = None
    note: str | None = None
    arg_supported: bool = True  # False: supported op handed an unsupported oparg
    arg_object: bool = False  # BINARY_OP routed to OBJECT via its oparg


class TargetModel:
    """Parsed target description with opcode resolution helpers."""

    def __init__(self, data: dict, source: pathlib.Path | None = None) -> None:
        self.source = source
        self.name = data["name"]
        self.python_version = data["python_version"]
        self.support_levels = data["support_levels"]
        self.hw_classes = {k: v for k, v in data["hw_classes"].items() if k != "//"}
        self.obj_groups = {k: v for k, v in data["obj_groups"].items() if k != "//"}
        self.opcodes = {k: v for k, v in data["opcodes"].items() if k != "//"}
        self.fold_groups = list(data["fold_groups"])
        self.max_fold_len = int(data["max_fold_len"])
        self._validate()
        self._opname_to_group = self._build_group_index()

    # -- construction helpers ------------------------------------------------

    def _validate(self) -> None:
        required_levels = {"execute", "partial", "strip", "trap", "reject"}
        missing = required_levels - set(self.support_levels)
        if missing:
            raise ValueError(f"target missing support_levels: {sorted(missing)}")
        for name, entry in self.opcodes.items():
            for key in ("support", "hw_class", "fold"):
                if key not in entry:
                    raise ValueError(f"opcode {name!r} missing {key!r}")
            if entry["support"] not in self.support_levels:
                raise ValueError(f"opcode {name!r} has unknown support {entry['support']!r}")
            if entry["hw_class"] not in self.hw_classes:
                raise ValueError(f"opcode {name!r} has unknown hw_class {entry['hw_class']!r}")
        for group in self.fold_groups:
            if "name" not in group or "cats" not in group:
                raise ValueError(f"fold_group missing name/cats: {group}")

    def _build_group_index(self) -> dict[str, str]:
        index: dict[str, str] = {}
        for group_name, group in self.obj_groups.items():
            for member in group.get("members", []):
                if member in index:
                    raise ValueError(
                        f"opcode {member!r} appears in obj_groups "
                        f"{index[member]!r} and {group_name!r}"
                    )
                index[member] = group_name
        return index

    # -- queries -------------------------------------------------------------

    def obj_group_of(self, opname: str) -> str | None:
        return self._opname_to_group.get(opname)

    def hw_meta(self, hw_class: str) -> dict:
        return self.hw_classes[hw_class]

    def classify(self, opname: str, arg: int | None = None) -> OpInfo:
        """Resolve an opcode (with its oparg) to a fully-populated OpInfo."""
        if opname in INTERNAL_OPNAMES:
            return self._make_info(
                opname, arg, support="strip", hw_class="INTERNAL", fold="BAR",
            )

        entry = self.opcodes.get(opname)
        if entry is not None:
            return self._classify_listed(opname, arg, entry)

        group = self.obj_group_of(opname)
        if group is not None:
            return self._make_info(
                opname, arg, support="trap", hw_class="OBJECT", fold="BAR",
                obj_group=group,
            )

        # Fall back to intrinsic derivation for any opcode the target omits.
        hw_class = derive_hw_class(opname)
        support = "strip" if hw_class == "INTERNAL" else (
            "trap" if hw_class == "OBJECT" else "reject"
        )
        return self._make_info(
            opname, arg, support=support, hw_class=hw_class,
            fold=derive_fold(opname), obj_group=self.obj_group_of(opname),
        )

    def _classify_listed(self, opname: str, arg: int | None, entry: dict) -> OpInfo:
        support = entry["support"]
        hw_class = entry["hw_class"]
        fold = entry["fold"]
        obj_group = None
        arg_supported = True
        arg_object = False

        if opname == "BINARY_OP" and arg is not None:
            args = entry.get("args", {})
            class_by_arg = args.get("class_by_arg", {})
            object_args = set(class_by_arg.get("OBJECT", []))
            alun_args = set(class_by_arg.get("ALUN", []))
            supported_args = set(args.get("supported", []))
            if arg in object_args:
                hw_class = "OBJECT"
                fold = "BAR"
                arg_object = True
                obj_group = _lookup_arg_group(args.get("obj_group_by_arg", {}), arg)
            elif arg in alun_args:
                hw_class = "ALUN"
            # numeric oparg the target cannot run breaks the fold and warns.
            if not arg_object and arg not in supported_args:
                arg_supported = False
                fold = "BAR"
        elif opname == "COMPARE_OP" and arg is not None:
            shift = entry.get("selector_shift", 5)
            selectors = set(entry.get("supported_selectors", []))
            if selectors and (arg >> shift) not in selectors:
                arg_supported = False

        return self._make_info(
            opname, arg, support=support, hw_class=hw_class, fold=fold,
            obj_group=obj_group, arg_supported=arg_supported, arg_object=arg_object,
            message=entry.get("message"), suggestion=entry.get("suggestion"),
            note=entry.get("note"),
        )

    def _make_info(
        self,
        opname: str,
        arg: int | None,
        *,
        support: str,
        hw_class: str,
        fold: str,
        obj_group: str | None = None,
        arg_supported: bool = True,
        arg_object: bool = False,
        message: str | None = None,
        suggestion: str | None = None,
        note: str | None = None,
    ) -> OpInfo:
        meta = self.hw_classes[hw_class]
        level = self.support_levels[support]
        distance = subsystem = None
        if obj_group is not None and obj_group in self.obj_groups:
            distance = self.obj_groups[obj_group].get("distance")
            subsystem = self.obj_groups[obj_group].get("needs_subsystem")
        return OpInfo(
            opname=opname,
            arg=arg,
            support=support,
            hw_class=hw_class,
            fit=meta["fit"],
            fold=fold,
            needs_leaf=meta.get("needs_leaf"),
            current_module=meta.get("current_module"),
            suppress=bool(meta.get("suppress", False)),
            severity=level["severity"],
            remediation=level["remediation"],
            obj_group=obj_group,
            obj_distance=distance,
            needs_subsystem=subsystem,
            message=message,
            suggestion=suggestion,
            note=note,
            arg_supported=arg_supported,
            arg_object=arg_object,
        )


def _lookup_arg_group(obj_group_by_arg: dict, arg: int) -> str | None:
    for group_name, args in obj_group_by_arg.items():
        if arg in args:
            return group_name
    return None


def _load_yaml(path: pathlib.Path) -> dict:
    try:
        import yaml  # type: ignore
    except ModuleNotFoundError as exc:  # pragma: no cover - depends on env
        raise RuntimeError(
            f"{path} is YAML but PyYAML is not installed; use a .json target"
        ) from exc
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def load_target(path: str | pathlib.Path) -> TargetModel:
    path = pathlib.Path(path)
    if not path.exists():
        raise FileNotFoundError(f"target file not found: {path}")
    if path.suffix in (".yaml", ".yml"):
        data = _load_yaml(path)
    else:
        data = json.loads(path.read_text(encoding="utf-8"))
    return TargetModel(data, source=path)
