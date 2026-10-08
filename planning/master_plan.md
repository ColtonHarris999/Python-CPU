# Master plan

PyCore is a CPython 3.14 bytecode CPU (hart) plus an RV32 companion
(`excore`) that finishes recoverable container work. Programs boot from a
host-built image, and the hart can now compile and run Python source
itself (`compile()`, string `exec` / `eval`, `bios()`).

This is the **only** living plan. It lists what is left to build, in the
order that unblocks the next step. Engineering cleanup (dead code, build
system, RTL structure) is tracked separately in
[`cleanup_report.md`](cleanup_report.md).

Snapshot: `main` @ `939c8c7` (PR #131 merged), 2026-09-29.

## Where the truth lives

```text
planning/master_plan.md          what is left to build (this file)
planning/cleanup_report.md       simplification / dead-code backlog
planning/old/                    archived designs (cited by section from code)
        │
        ▼
pycore/docs/*                    the machine as built: architecture, tags,
                                 bytecode_support, exception_support,
                                 object_model, compiler, exec_runner,
                                 code_loading, memory_hierarchy,
                                 string_accel
pycore/targets/pycore.json       machine-readable opcode / type catalog
pycore_firmware/builtins/*.md    ROM builtin inventory
excore/docs/*                    excore MMIO, ISA subset, firmware
```

Do not copy opcode tables or type lists into planning files. Point at
`pycore/docs/bytecode_support.md`, `pycore/docs/exception_support.md`,
and `pycore.json`, and update those in the same PR as the RTL change.

## What is on `main`

- Two-core system: pycore bytecode hart plus excore grow / extend / delete /
  bulk-update firmware over `trap_mailbox.sv`.
- Image boot from host CPython 3.14 (`image_from_source.py`, `pycore_cli.py`).
- Int / bool / float / complex ALU; strings (index, iterate, unit-step
  slice); lists, tuples, dicts, sets, `range`, `for`, comprehensions.
- Functions with defaults, `*args`, keyword-only arguments, `**kwargs`, and
  keyword calls; closures (cells and `OBK_FUNCTION`); module-level classes,
  instance attributes, and native methods.
- `try` / `except` / `else` / `finally`, `raise` of seeded types, MRO and
  tuple match, cross-frame unwind, catchable firmware raises, `e.args`.
- ROM builtins, including `compile()` (T1–T6 grammar), string `exec` /
  `eval`, and `bios(payload)`.
- `make run-file` / `make shell`: hand the hart a source file, compile
  and run it on device, and compare output and cycles with CPython
  (`pycore/docs/exec_runner.md`). `HOST_COMPILE=1` / `--host-compile`
  is the hardware-test path: CPython builds the image instead.
- Register-file ring with spill/fill (500-frame recursion, 64+ locals).
- Memory hierarchy: 8 KB L1I, 8 KB L1D, 128 KB L2, parameterized RAM,
  STRACC, CODC, GIC. Code ROM of 8192 slots plus 131 072 slots of writable
  code RAM.

The full "can I write this?" answer is the root `README.md` and
`make lint-file`.

## Known bugs

None open that are known. Both bugs PR #132 found were fixed in #131
(`dc5615c`): a `try` after an earlier call now catches (the caller's
code-entry slot is restored after a call), and the module-level `for`
loop "trap" was the image checker mistaking a module-level call for the
entry return. The live list of compiler bugs and ceilings is
[`pycore/docs/compile_limitations.md`](../pycore/docs/compile_limitations.md)
§3; add new finds there with a failing `img_compile_*` fixture.

Bugs found while writing the accelerator plan are listed with repros in
[`accelerator_split_plan.md`](accelerator_split_plan.md) Appendix A. Those
reproduced on the simulators are:
- excore `SET_UPDATE` hangs or drops elements on duplicates;
- excore `LONG_STR` hashing and equality differ from pycore's;
- a stale GIC after `ns['x'] = …` on the active globals dict;
- `in` over more than 256 elements hangs;
- name indexes ≥ 128 are truncated;
- `set()` drops `None`;
- bulk dict updates follow hash-slot order instead of insertion order;
- `1.0 in [1]` is False;
- held dmem requests execute twice at L1D (results unchanged, hit
  counters inflated about 2×);
- STRACC strings longer than 16 payload bytes built by concat, slice,
  join, strip, split and other copy-path producers carry a wrong hash, so
  they never equal or find an equal image constant (A26);
- three STRACC inputs hang (`"banana".rfind("x")` and two strips), and
  slices of wide strings keep the wide kind (A27, A28);
- `a.extend(a)` never terminates (A30);
- `int` overflow wraps silently at 64 bits (A32);
- `(1, 2) in [(1, 2)]` and `[1] in [[1]]` are False (A12).

Its Appendix E lists what the hart runs, traps on, or rejects at image
build across containers, calls, protocols and exceptions. §2.4 there
profiles the on-device compiler: 41% container ops, 40% instruction
fetch, `LOAD_GLOBAL` alone 17%.

Open hazards from the garbage-collection work (`pycore/docs/gc.md`):

| Bug | Symptom | Where to start |
| --- | --- | --- |
| `_bi_heap_release` with `GC_EN=0` hands back unzeroed bytes | A dict or set built after a release can see the released table's keys (`img_gc_release_zero` returns 4 with `+GC_EN=0`) | With GC on the release zeroes `[mark, old ptr)` at the next boundary (gc.md invariant 6). Doing the same with GC off changes cycle counts, so it waits for a baseline refresh |
| Run-time source that spells `_PYC_G` or `__dict__` without the program naming it | The image builder decides the compiler-cleanup descriptor and immutable type dicts from the names and string constants it can see (gc.md). `exec("_PY" + "C_G['k'] = [1]")` stores a heap value the collector does not trace and frees it | Either treat any run-time source with a non-constant argument as reaching every name (costs the compile-loop cleanup), or check at collection time that `_PYC_G` and the type dicts hold no dynamic pointers outside the scratch slots |
| GC mark stack on pathological graphs | Wide and deep live graphs mark with a bounded stack: one pop scans at most 128 slots and pushes the rest as a continuation, and a child that does not fit sends the range being scanned to a rescan list (`img_gc_wide_live_list`, `img_gc_deep_live_chain`, gc.md). The collection still raises `MemoryError` if more than 4,096 partly scanned ranges are pending at once: that takes a graph deeper than the 12,544-entry stack in which most nodes popped while it is full have several unmarked pushable children. The on-chip mark bitmap is 120 KB | A larger rescan list, or a rescan that walks the heap (needs object boundaries, which the extent bitmap does not record) |

## Open pull requests (parked)

These are parked until the owner decides to rebase or close them. Both are
100+ commits behind `main` and conflict with it.

| PR | Adds | Blocks |
| --- | --- | --- |
| [#99](https://github.com/ColtonHarris999/Python-CPU/pull/99) | `str.__class__` for `isinstance(s, str)`, T10 exception class bases, TUPLE dict keys | Exceptions T10 below |
| [#94](https://github.com/ColtonHarris999/Python-CPU/pull/94) | LIST / TUPLE `BINARY_SLICE` | Bytecode "list/tuple slicing" below |

Before starting either feature from scratch, read the parked PR.

## Tracks

Each track lists its next slice first.

### 1. Compiler and system software

| Item | State | Next step / trigger |
| --- | --- | --- |
| Self-hosting | **Unblocked on size** since code RAM doubled (#131): the resident package is 56 469 slots and 74 603 remain. Every compiler file already compiles on the host stand-in | Install the compiled copy and prove the fixpoint: `pycore/docs/compile_limitations.md` §1.3 |
| Grammar still `SyntaxError` | `class`, `import`, `with`, generators and generator expressions, `raise … from`, slice step and slice assignment, `*` / `**` unpacking at call sites and in displays, a second `for`/`if` in a comprehension, positional-only `/`, annotations, nested f-strings, format specs, `f"{x=}"`, `del` of a module-level name, non-literal defaults, `:=`, `match` | Full table with what each is blocked on: `pycore/docs/compile_limitations.md` §4. Some need hardware first (tracks 2 and 3); `*` / `**` unpacking, `/`, and a second comprehension clause are compiler-only work. Adjacent string literals are one `LOAD_CONST` (`pycore/docs/compiler.md`). Opcode inventory of the measured baseline suite: [`cpython_baseline_bytecode.md`](cpython_baseline_bytecode.md) |
| Compiler heap ceiling | Raised: the data window grew from 2 MB to 16 MB, so ~15 MB of heap is free at boot. `compile()` keeps roughly 10–16 KB per source line, so files of about a thousand lines fit (before, ~600 KB free capped files at ~60–100 lines). `cs_starred.py` (52 lines) needs 813 KB and would not have compiled before | O-2 or GC still matter for a long-running process that compiles repeatedly without mark/release |
| O-2 split result/scratch heap arenas | Not opened | The trigger was `img_compile_repeat` (heap watermark ≤ 400000) failing. The compiler heap ceiling above is now a second reason to open it. Caller mark/release is the reclaim path today |
| Module loader + relocation | Not opened | Only when code-RAM headroom runs out or a BIOS must load a payload from outside the image. The format is already recorded in `pycore/docs/code_loading.md` §4, so implement that rather than redesigning it |
| Garbage collection | Landed, off by default (`pycore/docs/gc.md`) | Turn it on by default after the full acceptance run passes on the 16 MB map. Code RAM is still not reclaimed (`_bi_code_mark` / `_bi_code_release`); see gc.md invariant 7 |
| `_bi_intern(s)` | Optional | Only if compiler names over 15 bytes make SHORT_STR policy fail |

#### On-device compiler vs CPython: opcode coverage

The on-device compiler ports CPython's front half (tokenizer, parser,
symbol table, codegen, assembler). As of the compiler-gaps work it also
runs a peephole pass and compiles `*` / `**` unpacking, so it emits 14 of
the 17 hardware opcodes it used to skip:

| Group | Opcodes | State |
| --- | --- | --- |
| Superinstructions | `LOAD_FAST_LOAD_FAST`, `STORE_FAST_LOAD_FAST`, `STORE_FAST_STORE_FAST` | **Landed** (peephole). A load is fused only when the local is provably bound, because the hart's paired load does not trap on `UNINIT` |
| `is None` jumps | `POP_JUMP_IF_NONE`, `POP_JUMP_IF_NOT_NONE` | **Landed** (peephole) |
| Starred forms | `CALL_FUNCTION_EX`, `DICT_MERGE`, `UNPACK_EX`, `LIST_EXTEND`, `SET_UPDATE`, `DICT_UPDATE`, `CALL_INTRINSIC_1` | **Landed**. Calls, displays, assignment and `for` targets. Still `SyntaxError`: a positional `*x` after a keyword argument, and a `*` target in a comprehension clause |
| Borrowed loads | `LOAD_FAST_BORROW`, `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | Not emitted: a refcount optimization, identical to `LOAD_FAST` on PyCore |
| Inlined comprehensions | `LOAD_FAST_AND_CLEAR` | Not emitted: comprehensions are nested functions (correct scoping, one call each). Optional perf work: cleanup item I1 |
| Not needed | `LOAD_FAST_CHECK`, `NOT_TAKEN` | Not emitted: plain `LOAD_FAST` already traps on `UNINIT`; `NOT_TAKEN` is a monitoring no-op |

The same work fixed a pre-existing miscompile: a `try` inside a `for`
loop recorded exception-table depth 0, so a raise dropped the loop
iterator (`pycore/docs/compile_limitations.md` §3.1).

### 2. Exceptions

Inventory: `pycore/docs/exception_support.md`. Unhandled raise is still
fatal `PY_TRAP_RAISE` (17). Hardware type/mem traps are **not** yet Python
exceptions.

| Track | What | Notes |
| --- | --- | --- |
| **T6** (next) | Hardware trap → catchable exception: `TypeError`, `ZeroDivisionError`, `AttributeError`, then `IndexError` / `KeyError` / `NameError` / `UnboundLocalError` | See the sketch below |
| T4 leftover | `RAISE_VARARGS` oparg 2 (`raise e from cause`); bare `raise` with no active exception should raise `RuntimeError` | Needs a `RuntimeError` boot sidecar |
| T7 | `LOAD_COMMON_CONSTANT` 0 → `AssertionError` for **host-built** images | The on-device compiler already rewrites `assert` to `LOAD_GLOBAL AssertionError` + `RAISE_VARARGS 1` |
| T9 | `with` (`LOAD_SPECIAL`, `WITH_EXCEPT_START`) | Needs `__enter__` / `__exit__` lookup |
| T10 | `class MyError(Exception)` | Parked in PR #99 |
| T5-B/C | More types (`OverflowError`, `ImportError`, `SystemExit`, …) | Seed a type only when a program needs its name |
| T11 | `except*` / exception groups | Later. A single `tp_base` cannot express dual inheritance |
| T12 | Generators / `GeneratorExit` | Together with `YIELD_*` |

Locks that still apply: do not bake type names into `CHECK_EXC_MATCH`;
never implement `SETUP_*` / `POP_BLOCK` (3.14 pseudo-ops); protocol
`StopIteration` stays identity against `iter_exhaust_type_r`; MRO depth 8;
recoverable excore traps stay mailbox completions, not Python exceptions.

**T6 sketch.** Seed boot-sidecar handles for the already-seeded types. The
sites that pulse `PY_TRAP_TYPE` / `PY_TRAP_DIV_ZERO` / `PY_TRAP_ATTR_ERROR`
(later index / key / name) construct an `OBK_EXCEPTION` and enter the
exception-table walk as if `RAISE_VARARGS 1` had run. Unhandled still ends in
trap 17. Do not convert recoverable mailbox traps.

### 3. Bytecode

Matrix: `pycore/docs/bytecode_support.md` and `pycore.json`.

| Opcode / ceiling | Why | Notes |
| --- | --- | --- |
| List / tuple `BINARY_SLICE` | Common in user code | Parked in PR #94 |
| `TO_BOOL` on `OBJECT` (`__bool__` / `__len__`) | Truthiness of user objects | Today TYPE-traps |
| `LOAD_SUPER_ATTR` | `super()` | Needed for method overriding |
| Negative indices | `xs[-1]` | Deviation 3 in `bytecode_support.md`. Rewrite with `len-1` until it hurts |
| `STR * INT` | String repeat | Today TYPE-traps |
| `STORE_SLICE`, `BUILD_SLICE`, slice step ≠ 1 | Slice assignment and stepped slices | `PY_TRAP_SLICE` exists only for `bytearray` |
| `FORMAT_WITH_SPEC` | Format-spec f-strings | |
| `LOAD_BUILD_CLASS` / `LOAD_LOCALS` | Runtime `class` (today classes are folded at image build) | Also unblocks `class` in the on-device compiler |
| `IMPORT_NAME` / `IMPORT_FROM` | `import` | Needs the module loader (track 1) |
| `YIELD_VALUE` / `SEND` / … | Generators | With T12 |
| `MATCH_*` | `match` | Low priority |

Never in v1 hardware: `SETUP_*` / `POP_BLOCK` (not in `co_code`), async
(`GET_AWAITABLE`, …), and `CACHE` in firmware-emitted code (fetch skips it;
the ROM compiler emits none).

**Policy for new opcodes.** Prefer a same-algorithm rewrite in firmware
(an index loop instead of a slice) over new hardware, unless the rewrite is a
known bug-farm (`lst.append(x)` → `lst += [x]` was one). Land the JSON
`support` / `plan_track` change and the human table in the same PR as the
RTL. Image tests use the shared simulator plusargs (`tools/ensure_sim.py`).

### 4. Builtins

Inventory: `pycore_firmware/builtins/builtins.md`.

| Item | Today | Target |
| --- | --- | --- |
| `getattr(obj, name)` with no default | returns `None` | raise `AttributeError` (firmware F2) |
| `min` / `max` of an empty iterable | returns `None` | raise `ValueError` (F2) |
| 27 not-implemented stubs (`open.py`, `super.py`, `hash.py`, …) | `return 1 % 0` bodies, **not seeded** into ROM, so a call is a missing-name `MEM_FAULT` | When one is seeded, it should `raise TypeError` (F3). See cleanup item F1 |
| `print` phase 2 | one INT / BOOL / None / SHORT_STR per `_bi_print`, through an excore trap | a pycore memory write to a console channel, with STRACC formatting every type: [`accelerator_split_plan.md`](accelerator_split_plan.md) §7–8, phases P1, P2 and P6 |
| `property` / `classmethod` / `staticmethod` | blocked | needs a descriptor protocol |

`hasattr` must stay non-raising. Leave blocked: async (`aiter` / `anext`),
files, `breakpoint`, `hash` as a Python builtin, `memoryview`,
`compile(..., flags≠0)`, `"single"` mode, `locals=` on `exec` / `eval`.

**ROM seed rule.** Do not seed CPython's full builtins dict. Boot-dict size
and 128 B per `OBK_TYPE` share the bump heap under `PYCORE_HEAP_LIMIT`. New
ROM bodies must pass `validate_code_tree` and, if they will be compiled on
device, the compiler subset gate (`test_compiler_subset.py`).

### 5. Accelerators and the excore split

Design and phases: [`accelerator_split_plan.md`](accelerator_split_plan.md).
The plan delivers:
- a container accelerator with separate data-ready and container-ready
  events;
- print as a pycore console write;
- `bytes`, `bytearray`, `int.from_bytes` and `int.to_bytes`;
- startup `ACCEL_CFG` registers with excore fallbacks;
- `excore_min` / `excore_full` and `rom_accel` / `rom_soft` builds;
- the excore as an emulator of unimplemented Python.

| Item | Today | Next step |
| --- | --- | --- |
| P0 groundwork | 27 compile-time `EXCORE_EN` routing sites; duplicate L1D requests; no runtime config; STRACC hash and hang bugs; word-serial L1I fills | Regression tests for the plan's Appendices A and E, the STRACC fixes of §8.0, L1I line fills, the memory fixes of §11, `ACCEL_CFG` + MCFG page + `pycore_route`, the key-spec package |
| P1 console | `print` traps to the excore per piece; single-core has no output | IO window and console channels, `CONSOLE_BASE`, `_bi_write` |
| P3 container accelerator | container work split between `S_CONTAINER` and excore traps 9–14 / 19–20 | CA stage A0, with the legacy path behind `ACCEL_CFG.CA = 0` |

## Memory-map locks

Do not move these without updating `encoding.py`, `pycore_defs.svh`,
`memory_hierarchy.md`, and `code_loading.md` together.
`test_memory_map_mirror.py` is the gate.

- Code ROM slots `0x0000..0x1FFF`; code RAM `0x2000..0x21FFF` (131 072 slots).
- Data window 16 MB (`DMEM_BLOCK_COUNT = 4096`), ending at the code base
  `0x0100_0000`. Boot record `0x3E0` (96 B); heap bump
  `0x440`..`PYCORE_HEAP_LIMIT` (`0xF00000`); exc-info arena
  `0xF00000..0xF00FFF`; native-method table `0xF00DE0`; frame descriptors
  `0xF01000..0xF08FFF`; RF spill LIFO `0xF40000..0xF7FFFF`.
- `CONSOLE_TX` at `0xF0`.

## Non-goals

- Running unmodified `vendor/pycpython` on the hart. It is the host oracle
  and algorithm source only.
- A PyPy / open-source tokenizer port.
- Merging the simulator UI (`ui` branch) onto `main`.
- New work on `preprocess.py` or `BOOT_EN=0` hex fixtures. Image boot is the
  only production path.

## Test contract

- Host: `make test-host` (CI job `host-tools`). Clone with
  `git submodule update --init` so `vendor/pycpython` is present.
- Device: every hardware test is a line in `pycore/programs/hw_tests.toml`,
  under the area it checks; `make test-<area>` runs one area and CI runs one
  job per area. They all share one `tb_container` binary per topology. Do
  not add per-fixture Verilator rebuilds.
- Architectural gate: `make test-caching` (CI job `caching`) must keep
  retired results identical with the cache off at latency 1, 4 and 30 and
  with the cache on at latency 30.
- **Device-compile suite** (`make test-compiler-vs-cpython`, CI job
  `compiler-vs-cpython`). The programs in `pycore/programs/compile_suite/`
  together cover the whole on-device compiler (every grammar tier and
  every emitted opcode family). Each is compiled **on the hart**, run on
  the hart, and its output compared with host CPython 3.14 compiling and
  running the same file. `CompileSuiteHostTest` runs the same programs on
  the host stand-in as a fast pre-check. The ~490 host-compiled
  hardware tests in `hw_tests.toml` stay the hardware tests. Add a program here
  when the compiler learns a new construct. Its first hart run found a compiler
  bug the stand-in hid (no `POP_EXCEPT` when leaving a handler early), an
  `assert` call shape the hart rejects, an excore `DICT_GROW` pop-count
  bug for `STORE_NAME`, and a stale `nlocals` after `RETURN` that put a
  later handler's stack too high; all fixed. `print()` of ints above 32 bits and
  `max(iterable)` are open (`cleanup_report.md` J1, J2).
