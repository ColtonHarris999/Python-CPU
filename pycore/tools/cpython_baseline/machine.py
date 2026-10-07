"""Adjustable machine specs for the CPython baseline.

A machine is a cache geometry plus the latencies that feed the simple-core
cycle model. Presets live in ``machines/*.toml``. Anything Callgrind can
simulate is expressible: two cache levels (split L1, unified last level),
power-of-two set counts, and a branch-mispredict penalty.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, replace
from pathlib import Path

_PRESETS = Path(__file__).resolve().parent / "machines"


@dataclass(frozen=True)
class CacheLevel:
    size_bytes: int
    associativity: int
    line_bytes: int
    hit_latency: int

    @property
    def sets(self) -> int:
        return self.size_bytes // (self.line_bytes * self.associativity)

    def callgrind(self) -> str:
        return f"{self.size_bytes},{self.associativity},{self.line_bytes}"

    def describe(self) -> str:
        size = self.size_bytes
        if size % 1024 == 0:
            label = f"{size // 1024}KB"
        else:
            label = f"{size}B"
        ways = "direct" if self.associativity == 1 else f"{self.associativity}-way"
        return f"{label}/{ways}/{self.line_bytes}B"


@dataclass(frozen=True)
class Penalties:
    """Extra cycles beyond the one-cycle-per-instruction base.

    ``l1i`` / ``l1d`` are the cost of a miss that hits the last-level cache.
    ``llc`` is the further cost of a miss that also misses the last level.
    ``branch`` is charged once per mispredicted conditional or indirect branch.
    """

    l1i: int
    l1d: int
    llc: int
    branch: int


@dataclass(frozen=True)
class Machine:
    name: str
    description: str
    model: str
    frequency_mhz: float
    branch_penalty: int
    l1i: CacheLevel
    l1d: CacheLevel
    llc: CacheLevel
    memory_latency: int
    penalties: Penalties
    source: str

    def to_json(self) -> dict:
        def level(c: CacheLevel) -> dict:
            return {
                "size_bytes": c.size_bytes,
                "associativity": c.associativity,
                "line_bytes": c.line_bytes,
                "hit_latency": c.hit_latency,
                "sets": c.sets,
            }

        return {
            "name": self.name,
            "description": self.description,
            "model": self.model,
            "frequency_mhz": self.frequency_mhz,
            "branch_penalty": self.branch_penalty,
            "l1i": level(self.l1i),
            "l1d": level(self.l1d),
            "llc": level(self.llc),
            "memory_latency": self.memory_latency,
            "penalties": {
                "l1i": self.penalties.l1i,
                "l1d": self.penalties.l1d,
                "llc": self.penalties.llc,
                "branch": self.penalties.branch,
            },
            "source": self.source,
        }


def preset_names() -> list[str]:
    return sorted(p.stem for p in _PRESETS.glob("*.toml"))


def preset_path(name: str) -> Path:
    path = _PRESETS / f"{name}.toml"
    if not path.is_file():
        known = ", ".join(preset_names()) or "(none)"
        raise FileNotFoundError(f"unknown machine {name!r}; presets: {known}")
    return path


def _power_of_two(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0


def _check_level(name: str, level: CacheLevel) -> None:
    if level.size_bytes <= 0 or level.line_bytes <= 0 or level.associativity <= 0:
        raise ValueError(f"{name}: size, line, and associativity must be positive")
    if not _power_of_two(level.line_bytes):
        raise ValueError(f"{name}: line size must be a power of two")
    if level.size_bytes % (level.line_bytes * level.associativity) != 0:
        raise ValueError(f"{name}: size must be a multiple of line size times ways")
    if not _power_of_two(level.sets):
        raise ValueError(
            f"{name}: set count must be a power of two "
            f"(size / (line * ways) = {level.sets}); Callgrind requires it"
        )
    if level.hit_latency < 0:
        raise ValueError(f"{name}: hit latency must be >= 0")


def _penalties(
    l1i: CacheLevel,
    l1d: CacheLevel,
    llc: CacheLevel,
    memory_latency: int,
    branch_penalty: int,
) -> Penalties:
    if llc.hit_latency < l1i.hit_latency or llc.hit_latency < l1d.hit_latency:
        raise ValueError("last-level hit latency must be >= each L1 hit latency")
    if memory_latency < llc.hit_latency:
        raise ValueError("memory latency must be >= the last-level hit latency")
    if branch_penalty < 0:
        raise ValueError("branch penalty must be >= 0")
    return Penalties(
        l1i=llc.hit_latency - l1i.hit_latency,
        l1d=llc.hit_latency - l1d.hit_latency,
        llc=memory_latency - llc.hit_latency,
        branch=branch_penalty,
    )


def _level(data: dict, name: str) -> CacheLevel:
    try:
        level = CacheLevel(
            size_bytes=int(data["size_bytes"]),
            associativity=int(data["associativity"]),
            line_bytes=int(data["line_bytes"]),
            hit_latency=int(data["hit_latency"]),
        )
    except KeyError as exc:
        raise ValueError(f"{name} is missing {exc}") from exc
    _check_level(name, level)
    return level


def load_toml(path: Path) -> Machine:
    raw = tomllib.loads(path.read_text(encoding="utf-8"))
    model = raw.get("model", "simple-core")
    if model != "simple-core":
        raise ValueError(
            f"machine model {model!r} is not implemented; the baseline uses "
            "simple-core (one cycle per retired instruction, plus miss and "
            "mispredict penalties). An out-of-order model would count the "
            "branch penalty twice on top of this formula."
        )
    l1i = _level(raw["l1i"], "l1i")
    l1d = _level(raw["l1d"], "l1d")
    llc = _level(raw["llc"], "llc")
    memory_latency = int(raw["memory"]["latency"])
    branch = int(raw["branch_penalty"])
    frequency = float(raw["frequency_mhz"])
    if frequency <= 0:
        raise ValueError("frequency_mhz must be positive")
    return Machine(
        name=str(raw.get("name") or path.stem),
        description=str(raw.get("description") or ""),
        model=model,
        frequency_mhz=frequency,
        branch_penalty=branch,
        l1i=l1i,
        l1d=l1d,
        llc=llc,
        memory_latency=memory_latency,
        penalties=_penalties(l1i, l1d, llc, memory_latency, branch),
        source=str(path),
    )


def load_machine(spec: str) -> Machine:
    """``spec`` is a preset name or a path to a TOML file.

    A bare name is always a preset. ``pycore`` is both a preset and a
    directory in this repository, so existence alone cannot decide.
    """
    path = Path(spec)
    if path.suffix == ".toml" or "/" in spec:
        if not path.is_file():
            raise FileNotFoundError(f"machine file not found: {spec}")
        return load_toml(path)
    return load_toml(preset_path(spec))


def apply_overrides(machine: Machine, overrides: dict) -> Machine:
    """Replace geometry or latencies. Empty values are left alone.

    Keys: l1i_bytes, l1d_bytes, llc_bytes, l1i_assoc, l1d_assoc, llc_assoc,
    line_bytes, l1i_hit, l1d_hit, llc_hit, mem_latency, branch_penalty, mhz.
    """
    if not any(v is not None for v in overrides.values()):
        return machine

    def level(base: CacheLevel, bytes_key: str, assoc_key: str, hit_key: str) -> CacheLevel:
        line = overrides["line_bytes"] if overrides.get("line_bytes") is not None else base.line_bytes
        updated = replace(
            base,
            size_bytes=overrides[bytes_key] if overrides.get(bytes_key) is not None else base.size_bytes,
            associativity=overrides[assoc_key] if overrides.get(assoc_key) is not None else base.associativity,
            line_bytes=line,
            hit_latency=overrides[hit_key] if overrides.get(hit_key) is not None else base.hit_latency,
        )
        _check_level(bytes_key.split("_")[0], updated)
        return updated

    l1i = level(machine.l1i, "l1i_bytes", "l1i_assoc", "l1i_hit")
    l1d = level(machine.l1d, "l1d_bytes", "l1d_assoc", "l1d_hit")
    llc = level(machine.llc, "llc_bytes", "llc_assoc", "llc_hit")
    memory = overrides["mem_latency"] if overrides.get("mem_latency") is not None else machine.memory_latency
    branch = overrides["branch_penalty"] if overrides.get("branch_penalty") is not None else machine.branch_penalty
    mhz = overrides["mhz"] if overrides.get("mhz") is not None else machine.frequency_mhz
    if mhz <= 0:
        raise ValueError("frequency must be positive")
    bits = [f"{key}={value}" for key, value in overrides.items() if value is not None]
    return Machine(
        name=machine.name + "+" + ",".join(bits),
        description=machine.description,
        model=machine.model,
        frequency_mhz=float(mhz),
        branch_penalty=int(branch),
        l1i=l1i,
        l1d=l1d,
        llc=llc,
        memory_latency=int(memory),
        penalties=_penalties(l1i, l1d, llc, int(memory), int(branch)),
        source=machine.source,
    )
