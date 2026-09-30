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
| Grammar still `SyntaxError` | `class`, `import`, `with`, generators and generator expressions, `raise … from`, slice step and slice assignment, `*` / `**` unpacking at call sites and in displays, a second `for`/`if` in a comprehension, positional-only `/`, annotations, nested f-strings, format specs, `f"{x=}"`, `del` of a module-level name, non-literal defaults, `:=`, `match` | Full table with what each is blocked on: `pycore/docs/compile_limitations.md` §4. Some need hardware first (tracks 2 and 3); `*` / `**` unpacking, `/`, and a second comprehension clause are compiler-only work |
| Compiler heap ceiling | Raised: the data window grew from 2 MB to 16 MB, so ~15 MB of heap is free at boot. `compile()` keeps roughly 10–16 KB per source line, so files of about a thousand lines fit (before, ~600 KB free capped files at ~60–100 lines). `cs_starred.py` (52 lines) needs 813 KB and would not have compiled before | O-2 or GC still matter for a long-running process that compiles repeatedly without mark/release |
| O-2 split result/scratch heap arenas | Not opened | The trigger was `img_compile_repeat` (heap watermark ≤ 400000) failing. The compiler heap ceiling above is now a second reason to open it. Caller mark/release is the reclaim path today |
| Module loader + relocation | Not opened | Only when code-RAM headroom runs out or a BIOS must load a payload from outside the image. The format is already recorded in `pycore/docs/code_loading.md` §4, so implement that rather than redesigning it |
| Garbage collection | Not opened | `compile()` leaks its working set; `_bi_heap_mark` / `_bi_heap_release` is the stopgap |
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
| `print` phase 2 | one INT / BOOL / None / SHORT_STR per `_bi_print` | LONG_STR on the sink, container `__str__`, `file=` |
| `property` / `classmethod` / `staticmethod` | blocked | needs a descriptor protocol |

`hasattr` must stay non-raising. Leave blocked: async (`aiter` / `anext`),
files, `breakpoint`, `hash` as a Python builtin, `memoryview`,
`compile(..., flags≠0)`, `"single"` mode, `locals=` on `exec` / `eval`.

**ROM seed rule.** Do not seed CPython's full builtins dict. Boot-dict size
and 128 B per `OBK_TYPE` share the bump heap under `PYCORE_HEAP_LIMIT`. New
ROM bodies must pass `validate_code_tree` and, if they will be compiled on
device, the compiler subset gate (`test_compiler_subset.py`).

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
