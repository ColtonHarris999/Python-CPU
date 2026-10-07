"""Simple-core cycle model on top of Callgrind event counts.

The model is the one Ismail and Suh used for interpreter measurements
(IISWC 2018), which is also the Hennessy and Patterson stall term:

    one cycle per retired instruction
    plus an extra penalty when an access misses L1
    plus a further penalty when that access also misses the last-level cache
    plus a penalty per mispredicted branch

An L1 hit is already paid for by the retired-instruction term. A last-level
miss is a subset of the L1 misses, so it pays ``P_L1 + P_LLC`` and not
``P_L1`` twice. ``P_L1 = T_LLC_hit - T_L1_hit`` and
``P_LLC = T_mem - T_LLC_hit``. Branch penalties follow RegCPython (TACO 2023):
the pipeline length, 16 cycles on their x86 machine, and the model is
adjustable because Eyerman, Smith, and Eeckhout (ISPASS 2006) show the
out-of-order penalty can differ.

This is not gem5's TimingSimpleCPU (that model stalls on every hit as well)
and it is not an O3 core. Adding ``P_br`` on top of an O3 simulation would
count the branch penalty twice.
"""

from __future__ import annotations

EVENT_NAMES = (
    "Ir",
    "Dr",
    "Dw",
    "I1mr",
    "D1mr",
    "D1mw",
    "ILmr",
    "DLmr",
    "DLmw",
    "Bc",
    "Bcm",
    "Bi",
    "Bim",
)


def blank_events() -> dict[str, int]:
    return {name: 0 for name in EVENT_NAMES}


def cycles(events: dict[str, int], penalties) -> int:
    """Retired-instruction cycles plus miss and mispredict stalls."""
    i1 = events["I1mr"]
    il = events["ILmr"]
    d1 = events["D1mr"] + events["D1mw"]
    dl = events["DLmr"] + events["DLmw"]
    br = events["Bcm"] + events["Bim"]
    return (
        events["Ir"]
        + i1 * penalties.l1i
        + il * penalties.llc
        + d1 * penalties.l1d
        + dl * penalties.llc
        + br * penalties.branch
    )


def sub_events(total: dict[str, int], part: dict[str, int]) -> tuple[dict[str, int], list[str]]:
    """``total - part``. Negative components are clamped to 0 and named."""
    out = blank_events()
    negative: list[str] = []
    for name in EVENT_NAMES:
        delta = total[name] - part[name]
        if delta < 0:
            negative.append(name)
            delta = 0
        out[name] = delta
    return out, negative


def add_events(parts: list[dict[str, int]]) -> dict[str, int]:
    out = blank_events()
    for part in parts:
        for name in EVENT_NAMES:
            out[name] += part[name]
    return out


def cache_metrics(events: dict[str, int]) -> dict:
    """Hit counts, hit rates, and misses per thousand instructions.

    Last-level lookups are the L1 misses (Cachegrind's LL is inclusive of
    those). Instruction hits are ``Ir - I1mr``. Data hits are
    ``(Dr + Dw) - (D1mr + D1mw)``.
    """
    ir = events["Ir"]
    l1i_miss = events["I1mr"]
    l1d_miss = events["D1mr"] + events["D1mw"]
    ll_miss = events["ILmr"] + events["DLmr"] + events["DLmw"]
    l1d_acc = events["Dr"] + events["Dw"]
    ll_acc = l1i_miss + l1d_miss

    def level(accesses: int, misses: int) -> dict:
        hits = accesses - misses
        return {
            "accesses": accesses,
            "misses": misses,
            "hits": hits,
            "hit_rate": (hits / accesses) if accesses else None,
            "mpki": (1000.0 * misses / ir) if ir else None,
        }

    cond = events["Bc"]
    ind = events["Bi"]
    branches = cond + ind
    mispreds = events["Bcm"] + events["Bim"]
    return {
        "l1i": level(ir, l1i_miss),
        "l1d": level(l1d_acc, l1d_miss),
        "llc": level(ll_acc, ll_miss),
        "branch": {
            "conditional": cond,
            "conditional_mispredicts": events["Bcm"],
            "indirect": ind,
            "indirect_mispredicts": events["Bim"],
            "mispredicts": mispreds,
            "mispredict_rate": (mispreds / branches) if branches else None,
            "mpki": (1000.0 * mispreds / ir) if ir else None,
        },
    }


def phase_view(events: dict[str, int], penalties, frequency_mhz: float) -> dict:
    cyc = cycles(events, penalties)
    ir = events["Ir"]
    return {
        "events": dict(events),
        "cycles": cyc,
        "cpi": (cyc / ir) if ir else None,
        "caches": cache_metrics(events),
        # cycles / (MHz * 1e6) seconds, in nanoseconds. This is the spec
        # clock, not the host's wall time.
        "simulated_ns": (cyc * 1000.0 / frequency_mhz) if frequency_mhz else None,
    }
