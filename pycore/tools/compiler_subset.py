"""Subset gate for ``pycore_firmware/compiler/``.

Walks the AST and compiled ``co_*`` fields of every file in the firmware
compiler tree. Algorithms live in ``planning/compiler_design.md`` §5.1.
"""

from __future__ import annotations

import ast
import pathlib
from dataclasses import dataclass

from image_from_source import (
    iter_code_objects,
    validate_code_object,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPILER_DIR = REPO_ROOT / "pycore_firmware" / "compiler"

# Post step-B frame window. Hardware today is tighter (32 locals) until the
# ring window lands; the compiler tree must satisfy the post-B cap so it
# keeps working once B is in.
FRAME_WINDOW_CAP = 200
STACKSIZE_CAP = 64

_BANNED_CALLS = frozenset(
    {"getattr", "hasattr", "setattr", "classmethod", "staticmethod", "property"}
)
_SEQUENCE_CTORS = frozenset({"list", "tuple", "dict", "set"})
_SKIP_NAMES = frozenset({"__pycache__"})


@dataclass(frozen=True)
class SubsetViolation:
    path: str
    message: str
    lineno: int | None = None

    def __str__(self) -> str:
        loc = f"{self.path}:{self.lineno}" if self.lineno else self.path
        return f"{loc}: {self.message}"


class SubsetError(ValueError):
    """One or more subset violations."""

    def __init__(self, violations: list[SubsetViolation]) -> None:
        self.violations = violations
        super().__init__(
            "compiler subset violations:\n"
            + "\n".join(f"  {v}" for v in violations)
        )


def _rel(path: pathlib.Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _is_str_constant(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and isinstance(node.value, str)


def _name_or_attr_id(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        return f"{node.value.id}.{node.attr}"
    return None


def _is_sequence_ctor_call(node: ast.AST) -> bool:
    if not isinstance(node, ast.Call):
        return False
    name = _name_or_attr_id(node.func)
    return name in _SEQUENCE_CTORS


def _is_sequence_literal(node: ast.AST) -> bool:
    return isinstance(
        node,
        (
            ast.List,
            ast.Tuple,
            ast.Set,
            ast.Dict,
            ast.ListComp,
            ast.SetComp,
            ast.DictComp,
            ast.GeneratorExp,
        ),
    ) or _is_sequence_ctor_call(node)


def _contains_usub(node: ast.AST) -> bool:
    for child in ast.walk(node):
        if isinstance(child, ast.UnaryOp) and isinstance(child.op, ast.USub):
            return True
    return False


def _slice_parts(slice_node: ast.AST) -> list[ast.AST]:
    if isinstance(slice_node, ast.Slice):
        parts = [p for p in (slice_node.lower, slice_node.upper, slice_node.step) if p is not None]
        return parts
    if isinstance(slice_node, ast.Tuple):
        out: list[ast.AST] = []
        for elt in slice_node.elts:
            out.extend(_slice_parts(elt))
        return out
    return [slice_node]


def _listy_names(tree: ast.AST) -> set[str]:
    """Names assigned a list/tuple/set/dict literal or constructor."""
    names: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        if not _is_sequence_literal(node.value):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name):
                names.add(target.id)
            elif isinstance(target, ast.Tuple):
                for elt in target.elts:
                    if isinstance(elt, ast.Name):
                        names.add(elt.id)
    return names


def check_source(source: str, *, filename: str = "<compiler>") -> list[SubsetViolation]:
    """Return subset violations for a single source string (no I/O)."""
    violations: list[SubsetViolation] = []
    try:
        tree = ast.parse(source, filename=filename)
    except SyntaxError as exc:
        violations.append(
            SubsetViolation(filename, f"syntax error: {exc.msg}", exc.lineno)
        )
        return violations

    listy = _listy_names(tree)

    for node in ast.walk(tree):
        lineno = getattr(node, "lineno", None)
        if isinstance(node, ast.ClassDef):
            violations.append(
                SubsetViolation(filename, "class is banned; use SoA arrays + functions", lineno)
            )
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            violations.append(
                SubsetViolation(filename, "import is banned; flatten into _PYC_G", lineno)
            )
        elif isinstance(node, ast.AsyncFunctionDef):
            violations.append(SubsetViolation(filename, "async def is banned", lineno))
        elif isinstance(node, ast.AsyncFor):
            violations.append(SubsetViolation(filename, "async for is banned", lineno))
        elif isinstance(node, ast.AsyncWith):
            violations.append(SubsetViolation(filename, "async with is banned", lineno))
        elif isinstance(node, ast.With):
            violations.append(
                SubsetViolation(filename, "with is banned; use try/finally", lineno)
            )
        elif isinstance(node, ast.Assert):
            violations.append(
                SubsetViolation(filename, "assert is banned; use if not x: raise", lineno)
            )
        elif isinstance(node, ast.Match):
            violations.append(SubsetViolation(filename, "match is banned", lineno))
        elif isinstance(node, ast.Lambda):
            violations.append(SubsetViolation(filename, "lambda is banned; use def", lineno))
        elif isinstance(node, ast.JoinedStr):
            violations.append(
                SubsetViolation(filename, "f-string is banned; use + / join", lineno)
            )
        elif isinstance(node, (ast.Yield, ast.YieldFrom, ast.Await)):
            violations.append(
                SubsetViolation(filename, "yield/await is banned; return a list", lineno)
            )
        elif isinstance(node, ast.Nonlocal):
            violations.append(
                SubsetViolation(filename, "nonlocal is banned (closures)", lineno)
            )
        elif isinstance(node, ast.FunctionDef) and node.decorator_list:
            violations.append(
                SubsetViolation(filename, "decorators are banned; use def", lineno)
            )
        elif isinstance(node, ast.Call):
            fname = _name_or_attr_id(node.func)
            if fname in _BANNED_CALLS:
                violations.append(
                    SubsetViolation(
                        filename,
                        f"{fname}() is banned; probe the dict directly",
                        lineno,
                    )
                )
        elif isinstance(node, ast.Compare):
            if (
                len(node.ops) == 1
                and isinstance(node.ops[0], (ast.Is, ast.IsNot))
                and isinstance(node.left, ast.Call)
                and isinstance(node.left.func, ast.Name)
                and node.left.func.id == "type"
            ):
                violations.append(
                    SubsetViolation(
                        filename,
                        "type(x) is T is banned; use tagged small ints",
                        lineno,
                    )
                )
        elif isinstance(node, ast.Dict):
            for key in node.keys:
                if isinstance(key, ast.Tuple):
                    violations.append(
                        SubsetViolation(
                            filename,
                            "tuple dict keys are banned; pack an int or nest dicts",
                            lineno,
                        )
                    )
        elif isinstance(node, ast.Subscript):
            parts = _slice_parts(node.slice)
            if any(_contains_usub(p) for p in parts):
                violations.append(
                    SubsetViolation(
                        filename,
                        "negative index is banned; use xs[len(xs)-1] / s[0:len(s)-1]",
                        lineno,
                    )
                )
            if isinstance(node.slice, ast.Slice) or (
                isinstance(node.slice, ast.Tuple)
                and any(isinstance(elt, ast.Slice) for elt in node.slice.elts)
            ):
                base = node.value
                base_name = base.id if isinstance(base, ast.Name) else None
                if _is_sequence_literal(base) or (base_name in listy):
                    violations.append(
                        SubsetViolation(
                            filename,
                            "list/tuple slice is banned; index-loop + append, or SoA ranges",
                            lineno,
                        )
                    )
                elif _is_str_constant(base):
                    pass
                elif isinstance(node.slice, ast.Slice) and node.slice.step is not None:
                    violations.append(
                        SubsetViolation(
                            filename,
                            "slice step is banned (BINARY_SLICE has no step)",
                            lineno,
                        )
                    )

    try:
        module_code = compile(source, filename, "exec")
    except SyntaxError:
        return violations
    except ValueError as exc:
        violations.append(SubsetViolation(filename, f"compile failed: {exc}"))
        return violations

    for co in iter_code_objects(module_code):
        window = co.co_nlocals + co.co_stacksize
        if window > FRAME_WINDOW_CAP:
            violations.append(
                SubsetViolation(
                    filename,
                    f"{co.co_name!r} frame window nlocals({co.co_nlocals})+"
                    f"stacksize({co.co_stacksize})={window} exceeds {FRAME_WINDOW_CAP}",
                )
            )
        if co.co_stacksize > STACKSIZE_CAP:
            violations.append(
                SubsetViolation(
                    filename,
                    f"{co.co_name!r} co_stacksize {co.co_stacksize} exceeds {STACKSIZE_CAP}",
                )
            )
        if co.co_freevars:
            violations.append(
                SubsetViolation(
                    filename,
                    f"{co.co_name!r} has freevars {co.co_freevars}; closures are banned",
                )
            )
        if co.co_cellvars:
            violations.append(
                SubsetViolation(
                    filename,
                    f"{co.co_name!r} has cellvars {co.co_cellvars}; closures are banned",
                )
            )
        try:
            validate_code_object(co)
        except ValueError as exc:
            violations.append(
                SubsetViolation(
                    filename,
                    f"{co.co_name!r} fails validate_code_tree: {exc}",
                )
            )

    return violations


def iter_compiler_sources(
    root: pathlib.Path | None = None,
) -> list[pathlib.Path]:
    root = pathlib.Path(root) if root is not None else COMPILER_DIR
    if not root.is_dir():
        return []
    files = [
        p
        for p in sorted(root.rglob("*.py"))
        if p.is_file() and not any(part in _SKIP_NAMES for part in p.parts)
    ]
    return files


def check_file(path: pathlib.Path) -> list[SubsetViolation]:
    text = path.read_text(encoding="utf-8")
    return check_source(text, filename=_rel(path))


def check_compiler_tree(root: pathlib.Path | None = None) -> list[SubsetViolation]:
    violations: list[SubsetViolation] = []
    for path in iter_compiler_sources(root):
        violations.extend(check_file(path))
    return violations


def assert_compiler_subset(root: pathlib.Path | None = None) -> None:
    violations = check_compiler_tree(root)
    if violations:
        raise SubsetError(violations)
