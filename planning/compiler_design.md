# PyCore on-device `compile()` — design

**Status:** design, ready for review → implementation
**Supersedes:** [`compile_plan.md`](compile_plan.md),
[`old/native_compiler_full_plan.md`](old/native_compiler_full_plan.md),
[`old/native_compiler_plan.md`](old/native_compiler_plan.md),
[`old/compile_fast_path.md`](old/compile_fast_path.md),
[`old/code_loading_bios_tokenizer_plan.md`](old/code_loading_bios_tokenizer_plan.md)
**Audience:** the implementing agent. This file is self-contained — you should
not need any of the superseded documents.

---

## 0. What this builds

`compile()` becomes a real PyCore builtin. Its bytecode and its code objects
are laid down by the image builder and are **resident in the machine's memory
at reset**, exactly like `print`, `sorted`, and `exec` are today. Nothing is
loaded, relocated, or JITted at boot.

```python
# on device, in a user program, with no host involvement
code = compile("1 + 2", "<s>", "eval")
assert eval(code) == 3
```

Four things make that work:

1. **A register file that supports ordinary Python.** Today live call depth is
   capped at roughly 25 frames by the 256-entry RF, and a function with more
   than 32 locals silently reads stale registers. A ring window with
   watermark spill/fill to dmem lifts both. This lands **first** (§6.1), on its
   own, before any compiler code — it is the highest-blast-radius change here
   and every later stage is easier once it is in.
2. **A compiler written in PyCore-subset Python**, derived from the
   [PyCPython](https://github.com/ColtonHarris999/PyCPython) host oracle at
   `vendor/pycpython`, living in a new tree `pycore_firmware/compiler/`.
3. **A boot image that seeds it**: the image builder compiles that tree with
   host CPython 3.14, places its bytecode in the code-RAM bank at elaboration,
   serializes its code objects and constants into the static dmem image, and
   binds `compile` in the boot-record builtins dict.
4. **Four new hardware builtins** (`_bi_code_alloc`, `_bi_code_blit`,
   `_bi_code_patch`, `_bi_code_new`) plus a code-memory **write path**, which
   is the only thing on the machine that Python cannot express.

Items 1 and 4 are the whole CPU delta; everything else is a rewrite of the
compiler. That split is deliberate and is argued in §3 and §6. Item 1 is not
strictly required to reach the acceptance test — the compiler is written to be
constant-depth regardless — but it is required for *user* programs compiled on
device to behave like Python, and it materially simplifies the codegen port
(§5.2 Rule 2).

---

## 1. Acceptance

The work is done when all of these are true.

| # | Criterion | How it is checked |
| --- | --- | --- |
| A1 | `eval(compile("1 + 2", "<s>", "eval")) == 3` on the two-core top | `img_compile_eval_expr` |
| A2 | `exec(compile(src, "<s>", "exec"))` runs a T1–T3 program and its globals match host CPython | `img_compile_exec_roundtrip` |
| A3 | The compiler never exceeds a constant call depth, whatever the source nests | `img_compile_deep_nesting` (40 nested parens) |
| A3b | A **user** program recursing ~500 frames deep, and a function with 64 locals, both run correctly | `img_rf_deep_recursion`, `img_locals_64` |
| A4 | A construct the machine cannot execute is a **`SyntaxError` from the compiler**, never an illegal-opcode or `CALL_FILTER` trap | `img_compile_reject_*` |
| A5 | `compile(src, f, "single")` and `flags != 0` raise `ValueError` | `img_compile_mode_trap` |
| A6 | The compiler's own source passes the subset gate | `test_compiler_subset.py` |
| A7 | Host differential: for every corpus program, the firmware compiler's **result** equals CPython's | `test_compiler_differential.py` |
| A8 | Image build fails, loudly, if the compiler overflows code RAM / heap | `make pycore-size-report` |

Explicitly **not** in scope: BIOS, module loader / relocation, string-form
`exec`/`eval` dispatch, self-hosting, garbage collection, `import`, closures,
generators, runtime `class`. §11 says where each of those goes afterwards.

---

## 2. Ground truth — what the machine does today

This section exists because several `pycore/docs/` and `planning/` statements
are **stale**, and three of them changed the right design. Everything below was
read out of the RTL and tooling at this commit; citations are `file:line`.

### 2.1 Capabilities the compiler can rely on

| Capability | Evidence | Consequence for this design |
| --- | --- | --- |
| **Runtime `LONG_STR` content equality** on `COMPARE_OP ==` / `!=` | `pycore/rtl/pycore_core.sv:840-852` routes distinct LONG/LONG with matching `(hash,nbytes,nchars,kind)` to `SA_CMP`; landed in `3a02b4c` | Identifier names may be **any length**. No interning builtin, no 15-byte name rule. |
| **`LONG_STR` ordering** (`<`,`<=`,`>`,`>=`) | same block, `PY_ALU_LT..GE` | Sorted name tables are fine. |
| **43 native `str` methods** on STRACC | `pycore/rtl/pycore_defs.svh:2047-2093`, decode at `:2139` | `split`, `rsplit`, `splitlines`, `partition`, `strip`, `replace`, `find`, `rfind`, `count`, `startswith`, `endswith`, `join`, `isdigit`, `isalpha`, `isalnum`, `isspace`, `isascii`, `upper`, `lower`, `removeprefix`, `removesuffix`, … are all **native**. The lexer can be written naturally. |
| String slicing with variable bounds | `BINARY_SLICE` → `SA_SLICE`, `pycore_core.sv:1000` | Source scanning is direct. |
| **Heap is ~960 KB** | `PYCORE_HEAP_BASE = 0x440`, `PYCORE_HEAP_LIMIT = 0xF0000` (`pycore_defs.svh:3098-3099`) | The old "106 KB heap" budget is obsolete by ~9×. A whole-module AST fits. |
| **Static string region is gone** | `pycore_string_mem.sv` deleted in `9e60071`; `STRING_HEX` is dead plumbing (`p5_review_followup.md` §4) | The old "16 KB of tables as strings" constraint does not exist. Tables are ordinary heap constants. |
| `try` / `except` / `else` / `finally`, `raise T("msg")`, `e.args` | `README.md` status; `pycore_cont_raise.svh` | The compiler may use `try/finally`. |
| `[0] * n` list repeat, `a + b` list concat | `CONT_SEQ_REPEAT`, `pycore_cont_list.svh:1739` | Arrays can be pre-sized, avoiding most `LIST_GROW` excore traps. |
| `LIST_TO_TUPLE` via `(*xs,)` | `CALL_INTRINSIC_1` arg 6 (`image_from_source.py:186`) | `co_consts` / `co_names` / `co_varnames` tuples are buildable from lists. |
| `_bi_exec_globals(code, dict)` | `PY_BI_EXEC_GLOBALS = 16` (`pycore_defs.svh:634`), FSM `pycore_call_fsm.svh:706` | Gives the compiler a **private namespace** with no new hardware (§4.2). |
| Heap + code mark/release | `PY_BI_HEAP_MARK..CODE_RELEASE` = 12–15 | Caller-driven lifetime control. |
| Code-RAM preload at elaboration | `pycore_ram.sv:209-211` loads `ram_slots` from `CODE_RAM_HEX`; `tb_container.sv:22,83` passes it | The compiler can be **resident at reset with zero RTL change**. |
| Code writes already traverse xbar → L2 → RAM | `pycore_mem_xbar.sv:139-149` (imem write with `wstrb` hi/lo select), `pycore_ram.sv:253-255, 286-288` (`code_arr` merge-strobe write) | The write path is 90% built (§6.2). |
| ROM write protection is enforced | `pycore_ram.sv:119-126`: a code write with offset `< PYCORE_CODE_RAM_BYTE_BASE` faults | The boot ROM cannot be scribbled by a buggy emitter. |

### 2.2 Stale statements to correct as part of this work

Fix these in the same commits that depend on them.

| Document | Stale claim | Truth |
| --- | --- | --- |
| `pycore/docs/string_accel.md` ("Equality") | "**LONG_STR ordering still TYPE-traps**"; runtime-built LONG vs interned copy "does not" compare equal | Both are handled by `SA_CMP` since `3a02b4c`. Needs a device fixture to pin it (§9 T0). |
| `compile_plan.md` ("Banned") | `str.split` / `strip` / `replace` banned; names > 15 bytes banned | All native now. Ban lifted (§5.1). |
| `planning/old/*` | heap ≈ 106 KB; 16 KB static string budget | 960 KB heap; no static string region. |
| `pycore/docs/code_loading.md` §1 | presents `pycore_code_mem.sv` / `pycore_code_ram.sv` as the live fetch path | Neither module is instantiated by `pycore_system.sv` or `pycore_excore_system.sv` (both use `pycore_mem_hier` → `pycore_ram`). They are compiled (`Makefile:55-56`) but dead. The ROM/RAM split lives inside `pycore_ram.sv`. Either delete them or mark them attic. |
| `pycore/docs/memory_hierarchy.md` invalidation matrix | heap release is absent from the CODC/GIC flush rows | `_bi_heap_release` can recycle an address a CODC/GIC entry is keyed on. Latent today (no runtime code objects); reachable after this work (§6.4). |

### 2.3 Hard constraints that shape the compiler

These are the ones that actually decide the architecture. Read them before
writing a line of the compiler.

**C1 and C2 are lifted by step B (§6.1).** They are stated here as the
machine's behaviour *today*, because step B is scheduled precisely to remove
them and because everything written before B lands must respect them.

**C1 — the per-frame locals cap, and a live bug behind it.**
`pycore_call_fsm.svh:2392, 2676`: `local_slots > 16'd32` → `call_filter_trap_r`.
Read carefully: `local_slots = meta_ac + varargs + varkw` is the **parameter**
count, not `co_nlocals`. There is no guard on `nlocals` anywhere — not in the
CALL FSM, not in `image_from_source.py`, not in the linter. Meanwhile
`pycore_regfile.sv:74-83` clears unbound locals with
`for (j = 0; j < LOCAL_COUNT; j++)` where `LOCAL_COUNT = 32`, while
`init_until_i` is driven from `call_nlocals_r` (`pycore_call_fsm.svh:291`).

So a function with 40 locals gets slots 32–39 **never UNINIT-cleared**: they
keep the previous frame's contents, `LOAD_FAST_CHECK` does not trap, and the
program reads a stale tagged value. `tos_r` is sized correctly from
`call_nlocals_r[6:0]`, so only the clear is short. This is an ordinary Python
function; the reason it has never fired is that the deepest function in the
whole `pycore/programs` corpus has 18 locals.

*Confirmed in simulation by `img_locals_40_uninit` (step B).* Step B fixed it and
`img_locals_40_uninit` pins it.

**C2 — the register file is shared by all live frames.**
`RF_DEPTH = 256`, `STACK_BASE = 32` (`pycore_core.sv:39-41`). A callee's locals
window starts at `tos - argcount` (`pycore_call_fsm.svh:55-57`), and
`new_locals_base + nlocals > STACK_TOP_MAX` is a `CALL_FILTER` trap
(`:2394`). So **live call depth is bounded by ~224 / (nlocals + stack) per
frame**, not by `MAX_CALL_DEPTH_CORE = 128`. `img_deep_callgraph` demonstrates
~25 live frames with tiny functions.

> Step B (§6.1) replaces the linear window with a ring plus spill/fill so
> ordinary programs (and a recursive-descent compiler) can run at depths the
> old ~25-frame cap forbade. Live depth is now the 1024-frame descriptor
> region, or the 8192-entry spill LIFO, whichever exhausts first. §5.2 keeps
> the parser iterative anyway, because not spilling is always cheaper than
> spilling well.

**C3 — no list/tuple slicing, no negative indices.** `xs[a:b]` on a
`LIST`/`TUPLE` and `xs[-1]` still trap. Strings are exempt (both work).

**C4 — the bump heap has no collector.** `_bi_heap_release` restores a cursor
and invalidates everything above it with no detection. `compile()` allocates
its working set and its result on the same cursor, so it **cannot** release
internally without destroying its own return value (§5.7).

**C5 — no `import`, no runtime `class`, no closures, no generators, no `with`,
no `assert`, no decorators, no `lambda`, no f-strings.** The compiler's own
source may not use them.

**C6 — `LOAD_GLOBAL` / `LOAD_NAME` resolve globals → builtins only.** There is
no module namespace and no LEGB **L** for `exec` scopes. A callee inherits the
caller's `globals_base_r` unless `_bi_exec_globals` changes it.

---

## 3. The three options you asked about

### 3.1 New bytecodes — **rejected**

The instinct is reasonable: emitting code and fabricating objects are the two
things Python cannot say, so give them opcodes. It is still the wrong lever
here, for four concrete reasons.

1. **It breaks the machine's defining property.** PyCore's ISA *is* a CPython
   3.14 bytecode subset, and `preprocessing_breakdown.md` §1 pins the fidelity
   boundary: "No opcode is added, removed, reordered, rewritten, or
   argument-remapped." A non-CPython opcode in `co_code` violates that at the
   image level, not just the doc level.
2. **Host CPython would never emit it.** The image builder compiles firmware
   with the real `compile()` (`image_from_source.py:1382`). A new opcode can
   only reach `co_code` through a post-pass that rewrites something — exactly
   the "heavy semantic lowering" that `preprocessing_breakdown.md` §3 forbids.
   It would also destroy the highest-leverage test asset on this path: running
   the identical firmware source under host CPython with Python stand-ins.
3. **The ripple is larger than the RTL.** A new opcode touches
   `pycore_decode.sv`, `pycore_defs.svh`, `pycore/targets/pycore.json`,
   `SUPPORTED_OPS`, `validate_code_tree`, the `btanalyze` analyzer, the linter,
   and `bytecode_support.md` — before any of it does useful work.
4. **The machine already has an opcode-extension mechanism, and it is better.**
   `CALL` on an `OBK_BUILTIN` handle enters a dedicated hardware sub-FSM with
   the arguments sitting in the register file (`pycore_call_fsm.svh:573+`).
   That is a new instruction in every way that matters — same RTL shape, same
   datapath — with none of the four costs above. `_bi_heap_mark`,
   `_bi_exec_globals`, `BI_LEN`, and `BI_RANGE` are all precedents.

The only scenario that would flip this is per-instruction emit cost dominating
compile time. §3.3 removes that scenario by making emit a bulk operation, so
the dispatch preamble is amortised over hundreds of words.

**Precedent to *not* follow:** `PY_OP_MEM_LOAD_PTR` / `PY_OP_MEM_STORE_PTR` are
internal-only opcodes outside the CPython space. They exist so testbenches can
drive the dmem datapath and are explicitly never emitted by tooling. They are
not a licence to put compiler primitives there.

### 3.2 `bytearray` as the memory-writing vehicle — **rejected**

The kernel of this idea is right and §3.3 keeps it. The vehicle is wrong.

- **`bytearray` is not implemented.** What exists is a tag kind
  (`PY_MUT_BYTEARRAY = 4`), a builtin id (`PY_BI_BYTEARRAY = 1`), an
  image-time allocator, and one helper predicate at
  `pycore_defs.svh:1140`. There is no `BUILD` path, no `BINARY_SUBSCR` /
  `STORE_SUBSCR`, no `len`, no append, no grow, no excore handler, and
  `PY_BI_BYTEARRAY` is not reachable in the CALL FSM. Making it usable means a
  new container family in `pycore_cont_*.svh` plus excore firmware for grow —
  **more RTL than the four builtins it would replace**, to reach the same
  place.
- **The unit is wrong.** A PyCore code word is 40 bits of payload
  (`(arg << 8) | opcode`, `encoding.py:599-602`) in a 64-bit slot. Bytes force
  the compiler to split each instruction into five and the hardware to
  reassemble it. A `list[int]` element already *is* the word.
- **It expands the language surface for nothing.** `bytes`/`bytearray` drag in
  their own equality, hash, repr, print, and iteration semantics — a whole type
  to specify and test, none of which the compiler needs.

### 3.3 Recommended: **bulk transfer over the types that already exist**

Keep the real idea — *write a block of memory in one operation instead of N* —
and spend it on a `LIST` of `INT`, which is fully supported end to end today.

| Builtin | Signature | Replaces |
| --- | --- | --- |
| `_bi_code_alloc(nslots)` | → `INT` base slot | — |
| `_bi_code_blit(base_slot, words)` | `words: list[int]` → `INT` count written | N× `_bi_code_emit` |
| `_bi_code_patch(slot, word)` | → `None` | jump backpatching |
| `_bi_code_new(fields)` | `fields: list` (9) → `CODE_OBJECT` | — |

Why this is the right shape:

- **One CALL per function body instead of one per instruction.** A 300-slot
  function is 1 builtin dispatch + a 300-iteration hardware loop, instead of
  300 full CALL round trips. The dispatch preamble (read `field0` val/tag,
  `field1` val/tag, branch — `pycore_call_fsm.svh:575-600`) is paid once.
- **Zero new types, zero new opcodes.** `list[int]`, `append`, `[0]*n`,
  `LIST_TO_TUPLE` are all shipped and regression-tested.
- **It composes with the IR.** §5.2's assembler already produces a flat
  `list[int]` of packed words as its natural output. `blit` consumes it
  verbatim; there is no marshalling step.
- **It is the same idea applied uniformly.** `_bi_code_new` takes one list of 9
  tagged fields rather than 9 arguments, so the FSM has one traversal loop and
  the argument-count check is `argc == 1`.

The same principle is applied *inside* the compiler as a
structure-of-arrays IR (§5.2), which is where it pays the most: it removes
per-node allocation, nested containers, and the need for list slicing.

**Net hardware cost of this path:** four `BI_*` sub-FSMs + one parameter flip
and one mux in the fetch/imem path. That is less RTL than making `bytearray`
minimally usable, and far less than a new opcode's ripple.

---

## 4. Where the compiler lives

### 4.1 Residency — code RAM preload, below a write floor

**Decision: R2.** The compiler's bytecode is written into the code-RAM bank at
elaboration via the existing `CODE_RAM_HEX` path; `code_ram_ptr_r` starts
immediately above it; hardware refuses any runtime write below that floor.

```text
slot 0x0000 … 0x1FFF   CODE ROM   boot image + existing ROM builtins   8 192 slots
slot 0x2000 … 0x2000+N CODE RAM   *** the compiler, preloaded ***      N slots, write-protected
slot 0x2000+N …        CODE RAM   runtime bump region                  32 768 - N slots
```

Rationale:

- `CODE_RAM_HEX` preload is **already live** (`pycore_ram.sv:209-211`,
  `tb_container.sv:83`) and already differentially tested
  (`pycore-img-code-ram-call` vs `…-rom`). Residency costs no RTL.
- ROM is 8 192 slots (`PYCORE_IMEM_BLOCK_COUNT = 16`) and already holds the
  boot image plus ~33 ROM builtin bodies. The compiler (§7) does not fit.
- Growing ROM would move `PYCORE_CODE_RAM_SLOT_BASE` (which is defined as the
  ROM slot count) and shift every `entry_slot` in every image — mechanical, but
  a bigger blast radius than a write floor.
- **The ROM guarantee is preserved where it matters.** `code_ram_ptr_r` is
  initialised from `CODE_RAM_INIT_SLOT` (`pycore_core.sv:51, 2187`). Setting
  that above the preloaded compiler and having `_bi_code_alloc` / `blit` /
  `patch` refuse `slot < code_ram_floor_r` makes the compiler as unwritable as
  ROM, for one comparator that the bounds check needs anyway.

**Alternative R1 (grow ROM to 32 768 slots)** stays on the table for a tape-out
that wants genuine mask-ROM immutability. It is a parameter change
(`PYCORE_IMEM_BLOCK_COUNT` 16 → 64) plus the `CODE_RAM_SLOT_BASE` move;
`pycore/tests/test_code_ram.py` already pins that the two move together. Do not
do it now.

**Required plumbing:** `+CODE_RAM_INIT_SLOT=` is a sim plusarg
(`pycore_core.sv`, `tb_container.sv`; shipped in step C / W-4). Step D emits
the value into `image.meta` so the shared `tb_container` binary is still
compiled once (§6.5 W-2).

### 4.2 Namespace — a private globals dict, via a builtin that already exists

**Problem.** The compiler has ~60 helper functions that call each other. Name
resolution on device is *current frame's globals → boot builtins* (C6), and a
callee inherits the caller's `globals_base_r`. So if a user program calls
`compile()`, every compiler frame would resolve names against **the user's
globals**. Putting 60 `_pyc_*` names into the boot builtins dict works but
leaks the compiler's internals into every program's name space and lets a user
global shadow a compiler helper.

**Solution, with zero new hardware.** `_bi_exec_globals(code, dict)` already
switches `globals_base_r` for one frame and restores it on return
(`pycore_call_fsm.svh:706`; `architecture.md` "Register file and frames").
Because ordinary `CALL` does not touch `globals_base_r`, **every frame nested
inside that call inherits the compiler's namespace**.

The image builder seeds one `MUT_DICT`, `_PYC_G`, holding every compiler
function as a `CODE_OBJECT` plus the compiler's constant tables. The public
builtin is a shim:

```python
# pycore_firmware/builtins/compile.py  (replaces the 1 % 0 stub)
def compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1):
    if flags != 0:
        raise ValueError("compile(): flags must be 0")
    if optimize != -1 and optimize != 0:
        raise ValueError("compile(): invalid optimize value")
    if mode != "exec" and mode != "eval":
        raise ValueError("compile() mode must be 'exec' or 'eval'")
    g = _PYC_G
    g["_in_src"] = source
    g["_in_file"] = filename
    g["_in_mode"] = mode
    return _bi_exec_globals(_PYC_ENTRY, g)
```

`_PYC_ENTRY` is a zero-argument `CODE_OBJECT` whose body is
`return _pyc_compile(_in_src, _in_file, _in_mode)`. Both `_PYC_G` and
`_PYC_ENTRY` are seeded in the boot builtins dict (two names, not sixty).

**Consequences to write down:**

- `compile()` is **not re-entrant** in v1 (the argument slots are globals).
  Detect it: `_PYC_G["_busy"]`; raise `RuntimeError`-shaped `ValueError` on
  re-entry. A nested `compile()` inside compiled-and-executed code is the
  realistic trigger; make it a clean error, not corruption.
- Every `STORE_NAME`/`STORE_GLOBAL` and every `globals_base_r` change flushes
  the GIC (`memory_hierarchy.md` invalidation matrix). Entering and leaving
  `compile()` therefore costs two GIC flushes. Acceptable; note it in the
  perf notes.
- The compiler may keep mutable module state in `_PYC_G` (arenas, counters).
  Reset it at entry, not at exit, so a trap mid-compile cannot poison the next
  call.

**Fallback F-A:** if `_bi_exec_globals` inheritance turns out not to hold for
some call shape (verify with `img_compile_ns_inherit` *first*, §9 T0), fall
back to prefixing every helper `_pyc_` and seeding them in the boot builtins
dict. Same compiler source; different seeding table. Budget one day.

### 4.3 The boot picture

```text
reset
 └─ S_BOOT reads the boot record at 0x3E0
      module CODE_OBJECT / globals dict / builtins dict
 builtins dict (static image) contains, among the existing names:
      "compile"   → CODE_OBJECT  (the shim above, in ROM)
      "_PYC_G"    → MUT_DICT     (the compiler namespace)
      "_PYC_ENTRY"→ CODE_OBJECT  (0-arg trampoline, in code RAM)
 _PYC_G (static image) contains:
      "_pyc_lex", "_pyc_parse", "_pyc_symtab", "_pyc_codegen",
      "_pyc_assemble", …        → CODE_OBJECT handles, entry_slot in code RAM
      "_PYC_KEYWORDS"           → MUT_DICT     (generated table)
      "_PYC_PREC", "_PYC_OPMAP" → TUPLE/LIST   (generated tables)
 code RAM slots [0x2000, 0x2000+N) hold every one of those bodies' bytecode
 code_ram_ptr_r = 0x2000 + N   (the write floor)
```

Nothing is allocated, copied, or relocated at boot. That is the "living in the
system's memory at startup" requirement, met literally.

---

## 5. The compiler

### 5.1 Subset rules for `pycore_firmware/compiler/`

Enforced by `pycore/tests/test_compiler_subset.py`, which walks the AST of
every file in the tree and the `co_*` fields of every compiled function.

**Banned — no rewrite needed, these are hard machine limits**

| Banned | Rewrite | Why |
| --- | --- | --- |
| `xs[a:b]`, `xs[i:]` on list/tuple | index loop + `append`, or SoA ranges | C3 |
| `xs[-1]`, `xs[i:-1]` on list/tuple | `xs[len(xs)-1]` | C3 |
| slice assignment | store loop | `STORE_SLICE` deferred |
| `class`, inheritance, `__slots__` | SoA arrays + functions (§5.2) | `LOAD_BUILD_CLASS` deferred |
| nested `def` closing over an outer local | explicit parameter, or `_PYC_G` state | `MAKE_CELL` deferred |
| `import` | one flattened package seeded into `_PYC_G` | no module objects |
| generators, `yield`, `async` | return a list | deferred |
| `with`, `assert`, `match` | `try/finally`, `if not x: raise` | deferred |
| decorators, `lambda` | `def` | keeps the subset small |
| f-strings | `+` / `"".join` | `FORMAT_WITH_SPEC` deferred |
| `getattr` / `hasattr` / `setattr` | direct dict probe | firmware `getattr` does not walk the MRO |
| `type(x) is str` | tagged small ints in the SoA arrays | `__class__` is OBJECT-only |
| tuple dict keys | packed `int` key, or nested dict | dict keys reject `TUPLE` |
| any function whose `nlocals + co_stacksize` exceeds the frame-window cap | split it | **C1**; after step B the cap is ~240, before it is 32 |
| unbounded recursion in the **parser** | explicit stacks (§5.2 Rule 2) | performance, not correctness, after step B |

**No longer banned** (old plans forbade these; §2.1 shows they work):

- `str.split` / `rsplit` / `splitlines` / `partition` / `strip` / `lstrip` /
  `rstrip` / `replace` / `find` / `rfind` / `count` / `startswith` /
  `endswith` / `join` / `isdigit` / `isalpha` / `isalnum` / `isspace` /
  `isascii` / `upper` / `lower` / `removeprefix` / `removesuffix`.
- Identifiers and dict keys **longer than 15 bytes**, and `==` on them.
- Sorting / ordering long strings.
- `try` / `except` / `finally`.
- List and dict **comprehensions** are permitted but discouraged in hot paths
  (each grow is an excore round trip); prefer a pre-sized `[0]*n`.

**Additional mechanical gates in `test_compiler_subset.py`:**

```
for every function F in pycore_firmware/compiler/:
    assert F.__code__.co_nlocals + F.__code__.co_stacksize <= 200   # C1, post-B
    assert F.__code__.co_stacksize <= 64             # keeps frames cheap to spill
    assert not F.__code__.co_freevars                 # closures
    assert not F.__code__.co_cellvars
    assert every opcode in F is in SUPPORTED_OPS      # validate_code_tree
    assert no BINARY_SLICE on a non-str (AST check)
    assert no UnaryOp(USub) inside a Subscript index  # negative index grep
```

### 5.2 The IR convention: structure-of-arrays, and iterative everything

This is the load-bearing rewrite. It is what lets the compiler run on a machine
with a 256-entry register file and no list slicing.

**Rule 1 — every IR is a set of parallel `list[int]` arrays in `_PYC_G`.**
No per-node object, no nested list, no tuple, no dict keyed by a pair. A
"pointer" is an `int` index. Fields are bit-packed into `int`s where they fit.

Tokens:

```python
# _PYC_G["tk_a"], ["tk_b"], ["tk_s"] — parallel, index = token id
tk_a[i] = kind | (col << 8) | (line << 24)      # kind 8b, col 16b, line 32b
tk_b[i] = start | (end << 32)                    # char offsets into source
tk_s[i] = text                                   # str for NAME/NUMBER/STRING, else None
```

96 B per token (three 32 B list cells) instead of 224 B for a 6-tuple in a
list. A 2 KB source is ~600 tokens ≈ 58 KB.

AST, with a flat child arena so arity is unbounded without nesting:

```python
nd_kind[n]                  # ND_* small int
nd_pos[n]  = line | (col << 32)
nd_a[n], nd_b[n], nd_c[n]   # child ids, or kid-arena (start, count), or an int operand
nd_obj[n]                   # str / int / float payload, or None
kids[]                      # flat arena; a variable-arity node stores (start, count)
```

Instructions, before assembly:

```python
ins_op[k], ins_arg[k], ins_line[k], ins_flag[k]   # flag bit 0: arg is a label id
lbl_at[L]                                          # label id → instruction index
```

Assembler output, ready for `_bi_code_blit`:

```python
words[j] = (arg << 8) | opcode        # exactly encoding.py:format_imem_slot
```

**Rule 2 — the front end does not recurse on source structure.**

Step B (§6.1) makes deep recursion *work*, so this stops being a correctness
requirement. It stays as a design rule for the passes where it is nearly free,
because not spilling is always cheaper than spilling well: every spilled entry
is two dmem writes on the way out and two reads on the way back.

| Pass | Shape | Why |
| --- | --- | --- |
| Expression parse | **required iterative**: explicit operand + operator stacks (precedence climbing / shunting-yard). `(`, `[`, `{` and call-open push a bracket marker; the matching close reduces down to it. | Highest fan-out in the compiler, and an expression is the one place a hostile input can nest 100 deep in 100 bytes |
| Statement parse | **required iterative**: one loop over the token stream with an explicit block stack driven by `INDENT` / `DEDENT` | Same, and it is already the natural shape |
| Symbol table | **may recurse** on AST depth | Bounded by source block nesting (single digits in practice) |
| Codegen | **may recurse** (`VISIT(expr)`) | This is the payoff of step B: PyCPython's `codegen.py` is method-recursive, so a recursive port tracks the oracle far more closely and is much easier to review than an explicit `(node, phase)` work stack |
| Assembler | already a loop | — |

> **Frame-depth guideline.** The parser's live call depth is constant,
> independent of the source. `img_compile_deep_nesting` (A3) pins it, and its
> golden includes the RF **spill count**, so a regression that reintroduces
> parser recursion shows up as spill traffic rather than as a silent slowdown.

This is also why LL(1) table generation is **not** needed: precedence climbing
with explicit stacks handles Python's expression grammar directly, and the
statement grammar is `INDENT`-delimited and effectively LL(1) on the first
token.

**Rule 3 — pre-size arrays.** `arr = [0] * n` before filling, then overwrite by
index. Each `append` past capacity is a `PY_TRAP_LIST_GROW` excore round trip;
pre-sizing turns hundreds of those into zero. Estimate `n` from
`len(source)` (tokens ≈ `len(src)//4`, nodes ≈ tokens, instructions ≈
`2 * nodes`) and grow by `+= [0]*n` doubling if the estimate is short.

### 5.3 PyCPython file-by-file disposition

`vendor/pycpython` stays **pristine** — it is the host oracle, and rewriting it
would destroy its 100% Tier 0/1 differential against CPython 3.14.7. Ports live
in `pycore_firmware/compiler/` with provenance headers and a
`pycore_firmware/THIRD_PARTY.md` entry (PSF-2.0).

| Vendor file | Lines | Disposition | Notes for the port |
| --- | ---: | --- | --- |
| `parser/generated_parser.py` | 14 040 | **never** | 455 PEG rule methods. Not portable, not needed — §5.2 Rule 2 replaces it. |
| `parser/pegen.py` | 1 455 | **never** | PEG runtime, inheritance, `unicodedata`, `os`, `sys`. |
| `marshal_writer.py` | 457 | **never** | `marshal` / `struct` / `weakref` / `sys.intern`. `_bi_code_new` replaces it. |
| `unparse.py` | 514 | **never** | Error-message pretty printer, 15 `LOAD_DEREF`. Use plain messages. |
| `tokenizer.py` | 2 018 | **reference** | Byte-oriented, uses classes / namedtuple / generators / `warnings`. Port the *state machine and token kinds* into `lexer.py` over a `str`, using the native `str` methods from §2.1. Keep it as the **host token-stream oracle**. |
| `codegen.py` | 3 966 (207 methods) | **reference, tier-limited** | The spec for "what CPython emits". Port only T1–T3 (§5.6) as flat functions over the SoA AST. Do not port pattern matching, async, generators, `class`, `import`, `with`, `finally`-in-codegen until the runtime exists. |
| `symtable.py` | 1 243 | **reference, subset** | Module + function scope, `global`. Drop PEP 695, type params, annotations, async, comprehension cells. Closures: **compute** them so you can raise a clear `SyntaxError`; never emit `MAKE_CELL`. |
| `flowgraph.py` | 1 974 | **selective** | Take jump sizing / `EXTENDED_ARG` reservation and the stack-depth walk. Skip every optimisation that assumes CPython's inline-cache layout. |
| `assemble.py` | 426 | **closest port** | Exception-table 6-bit varints, jump offsets, `co_stacksize`. Replace `build_code` / `marshal.loads` with `_bi_code_new`. Its varint writer is also the source for the host-side `encode_exception_table` (§6.5 W3). |
| `instrseq.py` | 79 | **port, flattened** | `Instruction`/`InstructionSequence` classes become the `ins_*` arrays. |
| `tokens.py` | 238 | **port, flattened** | Token kind ints, verbatim. |
| `errors.py` | 103 | **subset** | `SyntaxError(msg, (file, line, col, text))`. Drop `warnings.warn_explicit`. |
| `opcodes.py` | 1 019 | **host-generate** | Input to the generated device table (§5.4 `tables.py`). |
| `pyast.py` | 815 | **host-generate** | Field order is the reference for the `ND_*` kinds and their `nd_a/b/c` meanings. |
| `ast_preprocess.py` | 546 | **later** | Constant folding. Not v1 — the acceptance test passes either way (§5.6). |
| `parser/string_parser.py` | 407 | **selective, later** | Escape decoding. Needed when string literals with escapes enter the grammar. |
| `future.py` | 82 | **reject** | `from __future__ import` → `SyntaxError` in v1. |
| `compile.py` | 66 | **rewrite** | Becomes the shim in §4.2 plus `compile_main.py`. |

### 5.4 Device module layout

```text
pycore_firmware/compiler/
  tables.py        generated   ND_*, TOK_*, opcode numbers, keyword dict,
                               precedence table, emit allowlist
  lexer.py         ~400 lines  source str  → tk_* arrays
  parser.py        ~700 lines  tk_* arrays → nd_* / kids arrays   (iterative)
  symtab.py        ~250 lines  nd_* → scope tables                 (iterative)
  codegen.py       ~900 lines  nd_* + scopes → ins_* arrays        (iterative)
  assemble.py      ~350 lines  ins_* → words[] + metadata + exception table
  emit.py           ~80 lines  wrappers over _bi_code_alloc / blit / patch / new
  errors.py         ~60 lines  SyntaxError construction with position
  compile_main.py   ~60 lines  _pyc_compile(src, filename, mode)
```

`tables.py` is produced by a new host-only generator
`pycore/tools/gen_compiler_tables.py`, which reads
`pycore/targets/pycore.json` (the machine catalog) and the host `opcode`
module, and writes plain `dict` / `list` literals. Its output is **checked in**,
and a CI test asserts that regenerating it is a no-op. This is how the device
emit allowlist and the host linter cannot drift (A4).

### 5.5 Stage contracts

**Lexer** — `_pyc_lex(src) -> int` (token count; arrays in `_PYC_G`).
One index loop over `src`. Uses `src[i]`, `src[i:j]`, and the native
`isdigit`/`isalpha`/`isspace` methods. Emits `INDENT`/`DEDENT` from a
column stack (a `list[int]`, not slices). Handles `#` comments, line
continuations, `(`/`[`/`{` implicit joining, decimal / hex / float numerals,
and single- and triple-quoted strings without escapes in v1 (escapes are a
`tables.py`-driven pass added with `string_parser.py`). Reports the first
error as a `SyntaxError` with `(filename, line, col, text)`.

**Parser** — `_pyc_parse(mode) -> int` (root node id).
Statement loop + explicit block stack; expression parse by precedence climbing
with `opnd_stack` / `op_stack` in `_PYC_G`. Grammar tiers in §5.6.
`mode == "eval"` parses a single expression and wraps it in `ND_EXPRESSION`;
`mode == "exec"` parses a statement list into `ND_MODULE`.

**Symbol table** — `_pyc_symtab(root) -> int` (scope count).
One pass. For each function scope: parameters and every `STORE` target become
locals; anything else is global. `global x` forces global. A name that is local
to an enclosing function and read in a nested one is a **closure** →
`SyntaxError("closures are not supported on this target")`. Enforces D6
(`nlocals > 240` → `SyntaxError`; stacksize is the assembler's job).

**Codegen** — `_pyc_codegen(root, scope) -> int` (instruction count).
Explicit `(node, phase)` work stack. Emits only names in the generated
allowlist. **Emits no `CACHE`** — fetch skips opcode 0 anyway
(`pycore_fetch.sv:7-9`), and emitting none keeps jump deltas simple.
Deviations from CPython's codegen are enumerated in §5.8.

**Assembler** — `_pyc_assemble(...) -> CODE_OBJECT`.

1. Resolve labels to instruction indices, then to slot offsets.
2. Size jumps: reserve `EXTENDED_ARG 0` ahead of every forward jump so
   patching never resizes and no fixpoint iteration is needed.
3. CFG walk for `co_stacksize`. Reject `> 24` (C2 headroom) with a
   `SyntaxError`.
4. Encode the exception table as CPython 6-bit varints into a `TUPLE` of `INT`.
5. Pack metadata with the same bit layout as `encoding.py:pack_code_metadata`
   (`argcount[15:0]`, `nlocals[31:16]`, `stacksize[47:32]`,
   `kwonly[63:48]`, `CO_VARARGS[64]`, `CO_VARKEYWORDS[65]`,
   `posonly[81:66]`).
6. `base = _bi_code_alloc(len(words))`; `_bi_code_blit(base, words)`;
   backpatch any cross-function jump with `_bi_code_patch`.
7. `_bi_code_new([base, consts, names, meta_lo, defaults, varnames,
   kwdefaults, exctable, flags])`.

Nested code objects (a `def` inside the compiled module) are assembled
depth-first and land in the parent's `co_consts` before the parent is built.

### 5.6 Grammar tiers

| Tier | Constructs | Ship in |
| --- | --- | --- |
| **T1** | literals, names, `+ - * / // % ** & \| ^ << >> ~`, unary, comparisons incl. chains, `is`, `in`, `not`, `and`, `or`, calls, subscript, attribute, expression statements, assignment, `return` | v1 (A1) |
| **T2** | `if`/`elif`/`else`, `while`, `for`, `break`, `continue`, `pass`, augmented assignment, `del` | v1 (A2) |
| **T3** | `def` with positional / default / kw-only / `*args` / `**kwargs`, tuple unpacking, list / tuple / dict / set displays, `global` | v1 (A2) |
| T4 | `try`/`except`/`else`/`finally`, `raise`, comprehensions, string slicing | next |
| T5 | `class`, decorators, `import`, `lambda`, f-strings, `with`, `assert` | blocked on runtime tracks (§11) |

**No constant folding in v1.** CPython emits `LOAD_SMALL_INT 3` for `1 + 2`;
the firmware compiler emits `LOAD_SMALL_INT 1; LOAD_SMALL_INT 2; BINARY_OP +`.
Both evaluate to 3, which is what A1 checks. This is why **every differential
compares program results, never `co_code`** (§5.8 D1). Fold later by porting
`ast_preprocess.py`, if the size report wants the smaller output.

### 5.7 Lifetime and the heap

Per C4, `compile()` cannot `_bi_heap_release` internally: the returned
`CODE_OBJECT`, its `co_consts` tuple, and its strings sit above any mark the
compiler could take.

**v1 policy: the compiler does not release. It leaks its working set.**

- Document it in `compile.md` and `code_loading.md` §5.
- The *caller* controls lifetime with the public primitives, and this pattern
  goes in the docs:

  ```python
  hm = _bi_heap_mark(); cm = _bi_code_mark()
  code = compile(src, "<s>", "exec")
  exec(code)
  _bi_code_release(cm); _bi_heap_release(hm)   # invalidates `code` too
  ```

- Add `img_compile_repeat` (compile the same tiny source 8 times inside one
  mark/release pair) and assert the heap watermark stays under a golden. That
  turns a silent OOM into a test failure.

**Future O-2 (not now):** a second bump cursor allocating results downward from
`HEAP_LIMIT`, so scratch (upward) can be released independently. That is a real
allocator change; open it only if the working-set leak actually bites.

### 5.8 Documented deviations from CPython's compiler

Number these and pin them in `pycore/docs/compiler.md` (new) and
`bytecode_support.md`.

| # | Deviation | Consequence |
| --- | --- | --- |
| D1 | No `CACHE` padding is emitted | `co_code` differs from CPython; **results** must match. Never assert `co_code` identity. |
| D2 | No constant folding in v1 | Same. More instructions, same result. |
| D3 | `LOAD_GLOBAL` oparg is CPython 3.14's `namei = oparg >> 1`, bit 0 = push `NULL` | Must match hardware exactly. |
| D4 | `COMPARE_OP` uses CPython 3.14's packed oparg (selector in bits 7:5) | Must match hardware exactly. |
| D5 | Constructs the machine cannot execute are compile-time `SyntaxError` | Strictly better than CPython here; A4. |
| D6 | A frame window (`nlocals + co_stacksize`) over the cap in §6.1 S-6, or a closure, is a `SyntaxError` | The irreducible limit surfaced at compile time instead of as a fatal `CALL_FILTER`. Recursion depth is **not** a compile-time error — deep recursion is a runtime `MEM_FAULT` when the spill region is exhausted, which is CPython's `RecursionError` in kind. |
| D7 | `"single"` mode and `flags != 0` raise `ValueError` | Matches the stub contract in `compile.md`. |
| D8 | `filename` is stored, never opened | No filesystem. |
| D9 | `compile()` is not re-entrant | §4.2; clean error, not corruption. |

---

## 6. PyCore modifications — the complete list

Nothing outside this section changes. Every item says why no compiler rewrite
avoids it.

### 6.1 RTL — register-file ring window and the locals lift (S-1 … S-9)

This is the fix for C1 and C2. It is scheduled **first among the RTL work**
(step B, §9) because it changes the CALL/RETURN path that the code-emit
builtins in §6.2 also touch, and because every later stage is easier to write
once ordinary recursion and ordinary local counts work.

**Prior art in this repository.** `pycore/rtl/attic/pycore_frame_buffer.sv` is
a shelved prototype of a ring-plus-spill frame manager. Read it before
starting, then do **not** build it. It tracks residency per slot —
`slot_resident[64][64]`, `slot_reg_idx[64][64]`, `slot_map_addr[64][64]` —
roughly **170 Kbit of metadata to manage a 30 Kbit register file**, and its own
header concedes that "the caller's spilled slots are NOT automatically restored
on return." The design below deletes all of that bookkeeping by exploiting a
property the prototype did not use.

#### The property that makes this cheap

PyCore's RF is **strictly stack-disciplined**. A callee's window starts at
`tos - argcount` (`pycore_call_fsm.svh:55-57`), so windows only ever grow
upward with depth; `rs1_addr` / `rs2_addr` are always `locals_base + oparg` or
`tos - k` within the *current* frame; and nothing ever reads a suspended
frame's registers. Therefore **residency is a suffix property**: for a single
watermark `W`, entries `[W, tos)` are resident and everything below `W` is
spilled, in order.

One 8-bit register replaces the prototype's entire residency map. And because
spill order equals RF order equals dmem order, refill is a plain LIFO pop — no
address table, no per-slot mapping.

#### S-1 — make the window a ring

Turn the RF into a circular buffer over the **whole** `RF_DEPTH = 256`.
Retire `STACK_BASE = 32` and the special `RF[0..31]` base-frame region: under a
ring, frame 0 is just a frame. `RF_AW = 8` and 256 is a power of two, so
`tos_r` and `locals_base_r` wrap for free with no extra arithmetic — this is
the whole reason for choosing the full depth rather than the 224-entry region.

Do **not** implement this as a shift. `rf` is a flop array of 256 × 132 bits
(`pycore_regfile.sv:37`); moving it is a 33 792-bit memmove, either a
256-deep barrel shifter per bit or ~256 cycles. The pointer moves, the data
does not.

New state in `pycore_core.sv`:

```
rf_wm_r        [7:0]   oldest resident RF index; [rf_wm_r, tos_r) is resident
rf_resident_r  [8:0]   resident entry count (disambiguates full from empty)
spill_sp_r    [31:0]   dmem bump pointer, strict LIFO
```

#### S-2 — spill on CALL

The callee needs `need = nlocals + co_stacksize` entries. Both are already in
the code-object metadata (`pycore_code_meta_nlocals`,
`pycore_code_meta_stacksize`), so `need` is known before the frame is entered.

If `rf_resident_r + need > RF_DEPTH`, enter `S_RF_SPILL` and evict
`rf_resident_r + need - RF_DEPTH + RF_SPILL_HYST` entries from the watermark
upward. Each entry is two 128-bit dmem writes at a 32-byte stride — value at
`+0`, tag in the low nibble at `+16`, the same encoding
`heap_image._write_tagged` uses everywhere else — then `rf_wm_r++`,
`spill_sp_r += 32`, `rf_resident_r--`.

`RF_SPILL_HYST` (suggest 32 entries, ≈2 typical frames) is not optional. Without
it, a call/return pair straddling the watermark spills and refills the same
window every iteration — the classic SPARC register-window thrash.

**Spill must complete before reuse.** The attic module's header records this as
a bug it had to fix: freeing an RF register and allocating it to the incoming
frame before the old value reached dmem. `S_RF_SPILL` holds until the dmem ack.

*Optimisation, not required:* `pycore_cache.sv` has a full-line write path
(`line_i` / `wline_i`, used by STRACC). Two entries fit one 64-byte line, so a
line-granular spill halves the transactions. Land the simple version first.

#### S-3 — fill on RETURN

The restored frame needs `[locals_base_out, tos_base_out]` resident, and both
come straight out of the frame descriptor (`pycore_frame.sv:10-13`). If
`locals_base_out` lies below `rf_wm_r` in ring order, enter `S_RF_FILL` and
refill `(rf_wm_r - locals_base_out) mod 256` entries by popping the spill stack
in reverse: `rf_wm_r--`, `spill_sp_r -= 32`, `rf_resident_r++`.

Eager fill, not lazy. Lazy fill would need a residency check on every RF read —
a tag lookup in front of `rs1_o` / `rs2_o`, which are combinational reads on the
machine's most critical path. The refill quantity is known exactly, contiguous,
and issued as one burst, so eager costs nothing extra.

#### S-4 — rewrite the absolute guards

Every position compare that assumed a linear window becomes a
distance-from-watermark or occupancy check. These are in the trap path, so
getting one wrong converts overflow into silent corruption:

| Site | Today | Becomes |
| --- | --- | --- |
| `pycore_regfile.sv:51-53` | `tos_r < STACK_BASE \|\| tos_r > STACK_LAST` | overflow `rf_resident_r > RF_DEPTH`; underflow `rf_resident_r == 0` on a pop |
| `pycore_core.sv:1582` | `next_tos < STACK_BASE \|\| next_tos > STACK_TOP_MAX` | same occupancy check |
| `pycore_call_fsm.svh:2396, 2680` | `new_locals_base + nlocals > STACK_TOP_MAX` | `need > RF_DEPTH - RF_RESERVE` → `CALL_FILTER`; otherwise trigger S-2 |
| `pycore_call_fsm.svh:3873, 3956` | `tos_r + 1 > STACK_TOP_MAX` | occupancy check |

#### S-5 — lift the frame-descriptor depth cap

`MAX_CALL_DEPTH_CORE = 128` (`pycore_core.sv:1184`) is set well below what the
region already holds: `PYCORE_FRAME_STACK_BYTES = 0x8000` at
`FRAME_ENTRY_BYTES = 32` is **1024** descriptors. Raise it to 1024 so the RF is
no longer the binding limit and the descriptor region is.

#### S-6 — lift the locals cap (three separate defects)

1. **The short clear.** `pycore_regfile.sv:76`'s
   `for (j = 0; j < LOCAL_COUNT; j++)` with `LOCAL_COUNT = 32` cannot satisfy an
   `init_until_i` driven from `co_nlocals`. Rename the parameter
   `RF_INIT_CHUNK` (entries cleared per cycle, default 32) and add an
   `S_RF_INIT` loop state in the core for
   `nlocals - argcount > RF_INIT_CHUNK`. Common functions still clear in one
   cycle; large ones take a few more. **This is the C1 bug fix.**
2. **The parameter cap.** `local_slots > 16'd32` (`pycore_call_fsm.svh:2392,
   2676`) caps parameters. Raise it to the window cap below. Note the
   positional-fill mask `call_range_start_r` is already 128 bits wide, so the
   arg-binding path does not itself need 32.
3. **The silent truncations.** `call_nlocals_r[6:0]` (`:293`) and the ~20
   `cur_arg_r[6:0]` / `call_argcount_r[6:0]` sites truncate at 128 with no
   trap. Widen to `RF_AW`.

**The one cap that stays.** A frame's whole window must be simultaneously
addressable, so `nlocals + co_stacksize ≤ RF_DEPTH - RF_RESERVE` (≈ 240).
Spilling *within* a frame is what would reintroduce the per-slot residency map,
so it is deliberately out. 240 is far past anything CPython emits; it must be a
clean `CALL_FILTER` and a compile-time `SyntaxError` (D6), never silence.

#### S-7 — the spill region

Spill needs its own dmem region; the 32 KB frame area holds descriptors only.

```
PYCORE_RF_SPILL_BASE  = 0x0010_0000
PYCORE_RF_SPILL_BYTES = 0x0004_0000      # 256 KB = 8192 entries
```

Growing the data map to reach it is `PYCORE_DMEM_BLOCK_COUNT` 256 → 512, which
only moves `DATA_LIMIT` — the backing array `PYCORE_RAM_BYTES` is already 16 MB
(`pycore_defs.svh:41`), so nothing new is allocated. Exhausting the region is
`PY_TRAP_MEM_FAULT` with a "call stack too deep" note: a documented, growable
resource limit in the same spirit as CPython's `RecursionError`, replacing
today's ~25-frame `CALL_FILTER`.

#### S-8 — coherence, and what we get for free

Spill and fill use the **ordinary dmem master**, so they land in L1D like any
other access. That is the entire payoff for not building a dedicated stack
cache: the frame region already hits L1D at **99.58% / 95.29%**
(`img_recursion` / `img_deep_callgraph`, `memory_hierarchy.md` P8 skip table —
which is why P8 was skipped in the first place), and `trap_req` already
write-backs and invalidates L1D before granting dmem to excore, so spilled data
is automatically visible there. **No new row in the invalidation matrix, and no
new coherence obligation.**

One invariant to state and assert: `S_RF_SPILL` / `S_RF_FILL` are entered only
from `S_CALL` / `S_RETURN` and never overlap a container trap marshal, so the
spill path and `S_TRAP_MARSHAL` can never contend for the dmem port.

#### S-9 — tests

| Test | Checks |
| --- | --- |
| `img_locals_40_uninit` | a 40-local function reading an unassigned late local traps `MEM_FAULT`; **fails on `main` today** (C1 bug) |
| `img_locals_64` | a 64-local function computes correctly (A3b) |
| `img_rf_deep_recursion` | ~500-frame recursion returns the host-CPython golden (A3b) |
| `img_rf_spill_refill` | a spilled frame's locals are intact after return |
| `img_rf_thrash` | a call/return pair straddling the watermark, run 1000×; spill count golden proves hysteresis works |
| `img_rf_window_too_big_trap` | `nlocals + stacksize` over the cap → `CALL_FILTER` |
| `img_rf_spill_oom_trap` | unbounded recursion → `MEM_FAULT`, not corruption |
| `tb_regfile` directed | ring wrap at index 255→0, occupancy full/empty disambiguation |
| every existing image test | unchanged results — this is a differential against the whole current suite, and it is the real acceptance gate for step B |

### 6.2 RTL — the code-memory write path (R-1 … R-4)

The path is mostly built. What follows is the actual delta.

**R-1 — L1I must accept writes.** `pycore_mem_hier.sv:134` instantiates the L1
instruction cache with `READ_ONLY(1'b1)`, and `pycore_cache.sv:396` turns any
write into `ack + fault`. Change L1I to a **write-invalidate, no-allocate**
policy: on a write request, invalidate the matching line if present, then
forward the write downstream unmodified. Do not merge data into L1I — it never
needs to serve the value it just wrote.

Downstream is already correct:
- `pycore_mem_xbar.sv:139-149` forwards `imem_we_i` to L2 with the right
  128-bit `wstrb` hi/lo selection for a 64-bit code slot.
- L2 is `READ_ONLY(0)`, `WRITE_BACK(1)` (`pycore_mem_hier.sv:277-278`).
- `pycore_ram.sv:253-255, 286-288` merge-strobe into `code_arr`, and
  `:119-126` **faults** any code write below `PYCORE_CODE_RAM_BYTE_BASE`, so
  the boot ROM is already protected in hardware.

**R-2 — the core must be able to drive the imem port.** `pycore_fetch.sv:73`
hardwires `imem_we_o = 1'b0`. Mirror the existing dmem pattern
(`pycore_core.sv:1128-1143`, where `S_CALL` overrides `ms_dmem_*` for spill
writes): add an `S_CODE_WRITE` state that owns `imem_req_o` / `imem_we_o` /
`imem_addr_o` / `imem_wdata_o` while `pycore_fetch` is stalled. Fetch keeps
driving `imem_we_o = 0` on its own outputs; the mux selects.

**R-3 — the fetch line buffer must be invalidated.** `pycore_fetch.sv:57-60`
holds a 64 B line register (`line_valid_r`, `line_tag_r`). A blit that touches
a line already in that register leaves stale instructions visible. Add a
`code_write_i` input that clears `line_valid_r`. Cheap and mandatory.

**R-4 — the write floor.** `code_ram_ptr_r` initialises from
`CODE_RAM_INIT_SLOT` (`pycore_core.sv:51, 2187`). Latch that initial value as
`code_ram_floor_r`. Then every written slot `s` must satisfy
`code_ram_floor_r <= s < PYCORE_CODE_RAM_SLOT_LIMIT`, else `PY_TRAP_MEM_FAULT`:
`_bi_code_alloc` checks the whole reserved range before moving the cursor;
`_bi_code_blit` and `_bi_code_patch` check every slot they touch. This is what
makes the preloaded compiler (§4.1) as immutable as ROM. Note the cursor can
only move below the floor via `_bi_code_release`, which already validates its
mark against `CODE_RAM_INIT_SLOT`.

*No compiler rewrite avoids R-1…R-4:* code memory is a different address space
from the heap. Python has no expression for it.

### 6.3 RTL — four `BI_*` builtins (R-5)

Add ids after `PY_BI_EXEC_GLOBALS = 16` in `pycore_defs.svh:613-634` and mirror
them in `pycore/tools/encoding.py:290+`. Each gets a `call_sub_r` block in
`pycore_call_fsm.svh` phase 13, alongside `BI_LEN` / `BI_RANGE` /
`BI_EXEC_GLOBALS`.

Word format is fixed and shared with the image builder:

```
slot word[63:0] = (oparg[31:0] << 8) | opcode[7:0]      # encoding.py:599-602
bits [63:40] must be zero
```

| Id | Builtin | argc | Behaviour | Traps |
| ---: | --- | ---: | --- | --- |
| 17 | `_bi_code_alloc(nslots)` → `INT` | 1 | `base = code_ram_ptr_r; code_ram_ptr_r += nslots; return base` | argc ≠ 1 or non-`INT` → `CALL_FILTER`; `nslots <= 0` → `TYPE`; `base + nslots > CODE_RAM_SLOT_LIMIT` → `MEM_FAULT` |
| 18 | `_bi_code_blit(base, words)` → `INT` | 2 | walk the `MUT_LIST`: read `length`, `ob_item`, then per element read val/tag at `ob_item + i*32` / `+16`, require `INT`, write the low 40 bits to code slot `base + i`. Return the count. Do **not** mask a malformed word — trap it. | non-`INT` base or non-`LIST` words → `TYPE`; any element not `INT` → `TYPE`; `word[63:40] != 0` → `TYPE`; range violation (R-4) → `MEM_FAULT` |
| 19 | `_bi_code_patch(slot, word)` → `None` | 2 | single-slot overwrite; same checks as blit | as above |
| 20 | `_bi_code_new(fields)` → `CODE_OBJECT` | 1 | `fields` is a `MUT_LIST` of exactly 9 tagged entries (table below). Allocate `CODE_OBJECT_BYTES = 256` from `heap_ptr_r`, write the 8 fields at the tuple-element stride, fold `fields[8]` flags into the metadata word, return a `PY_TAG_CODE_OBJECT` handle. | length ≠ 9, or any field tag wrong → `TYPE`; `entry_slot` outside `[code_ram_floor_r, code_ram_ptr_r)` → `MEM_FAULT`; heap OOM → `MEM_FAULT` |

`_bi_code_new` field contract — matches `encoding.py:262-271` and
`architecture.md` "Image boot and code objects":

| i | Field | Required tag |
| ---: | --- | --- |
| 0 | `entry_slot` | `INT` |
| 1 | `co_consts` | `TUPLE` |
| 2 | `co_names` | `TUPLE` |
| 3 | `metadata` low 64 bits | `INT` |
| 4 | `co_defaults` | `TUPLE` |
| 5 | `co_varnames` | `TUPLE` |
| 6 | `co_kwdefaults` | `MUT_DICT` |
| 7 | `co_exceptiontable` | `TUPLE` of `INT` |
| 8 | flags: `CO_VARARGS` \| `CO_VARKEYWORDS` \| `posonlyargcount << 2` | `INT` |

Field 8 exists separately because `posonlyargcount` sits at metadata bits
`[81:66]`, above the 64-bit `INT` payload — the hardware recombines them.

*No compiler rewrite avoids R-5:* `CODE_OBJECT` is a tag no Python expression
constructs, and code-RAM reservation is not a heap operation.

### 6.4 RTL — cache and inline-cache coherence (R-6)

Update `pycore/docs/memory_hierarchy.md`'s invalidation matrix and implement
these rows:

| Event | L1I | L1D | L2 | CODC | GIC |
| --- | :-: | :-: | :-: | :-: | :-: |
| `_bi_code_blit` / `_bi_code_patch` write | **inv** | — | (write goes through) | **flush** | — |
| `_bi_code_new` | — | — | — | **flush** | **flush** |
| `_bi_heap_release` | — | — | — | **flush** | **flush** |

Why the last two rows matter: the CODC is keyed on a code object's **address**
(`pycore_codc.sv:6-14`) and the GIC on `{code_addr, namei}`
(`pycore_gic.sv:5-11`). A `_bi_heap_release` followed by a new allocation can
place a *different* code object at an address a cached entry still names. That
is unreachable today because no code object is ever created at runtime; it
becomes reachable the moment `_bi_code_new` exists. Treat it as a latent bug
this work must close, not as new scope.

### 6.5 Tooling (W-1 … W-8)

| # | Change | Why |
| --- | --- | --- |
| **W-1** | `seed_firmware_package()` in `image_from_source.py` | Today `seed_firmware_function` (`:1370`) seeds exactly one function per file. The compiler is ~60 functions across 9 files. New helper: compile each module, serialize every top-level `def` as a `CODE_OBJECT`, build the `_PYC_G` dict, and bind `_PYC_G` / `_PYC_ENTRY` in the boot builtins dict. |
| **W-2** | Per-code-object **bank assignment** in the serializer | `--code-ram` today relocates the *whole* image. Add a per-object region choice so ROM keeps the boot image + existing builtins while the compiler goes to code RAM. Emit `code_ram.hex` alongside `program.hex` and report `CODE_RAM_INIT_SLOT` in `image.meta`. |
| **W-3** | `encode_exception_table()` in `pycore/tools/exception_table.py` | The file only *parses* 6-bit varints today. PyCPython `assemble.py` is the reference. Property test: `encode(parse(x)) == x` over the corpus. |
| **W-4** | `+CODE_RAM_INIT_SLOT=` plusarg in `pycore_core.sv` + `tb_container.sv` + Makefile recipes | `HEAP_INIT_PTR` already works this way (`pycore_core.sv:340`). Without it, placing the compiler would force a per-image Verilator rebuild, which the test contract forbids. |
| **W-5** | Host stand-ins for the four builtins in `load_rom_firmware_callables()` | The highest-leverage test asset: the identical firmware source runs under host CPython, accumulating words and building a real `types.CodeType`. This is how stages are debugged off-device. |
| **W-6** | `pycore/tools/gen_compiler_tables.py` → `pycore_firmware/compiler/tables.py` | One source of truth (`pycore/targets/pycore.json`) for the device emit allowlist and the host linter. CI asserts regeneration is a no-op. |
| **W-7** | `pycore/tests/test_compiler_subset.py` | §5.1 gate. Write it **first** — it is step A in §9, and it is pure host Python, so it can land while step B is in flight. |
| **W-8** | `make pycore-size-report` | Per-region slots / heap bytes vs ceilings; **fails the build** on overflow (A8). |

### 6.6 Documentation to update in the same commits

| Doc | Change |
| --- | --- |
| `pycore/docs/compiler.md` | **new** — pipeline, SoA IR, frame-depth invariant, tiers, D1–D9 |
| `pycore/docs/code_loading.md` | §2 writers now shipped; §1 corrected (`pycore_code_mem.sv` is not the live path); §5 gains the compile lifetime pattern |
| `pycore/docs/object_model.md` | new `BI_*` ids 17–20 |
| `pycore/docs/memory_hierarchy.md` | invalidation matrix rows from §6.4; RF spill traffic is an ordinary dmem master (S-8) |
| `pycore/docs/architecture.md` | "Register file and frames" — ring window, spill/fill, new depth and window limits; retire the `RF[0..31]` / `RF[32..95]` split |
| `pycore/rtl/attic/README.md` | note that `pycore_frame_buffer.sv` was superseded by §6.1 and why |
| root `README.md` | the "96-entry RF" / `RF[0..31]` description is wrong today (it is 256) and changes again with S-1 |
| `pycore/docs/string_accel.md` | remove the stale LONG_STR equality/ordering claims (§2.2) |
| `pycore/docs/bytecode_support.md` | D1–D9 |
| `pycore_firmware/builtins/compile.md` | blocker notes → shipped subset |
| `pycore_firmware/README.md` | the `compiler/` tree |
| `pycore_firmware/THIRD_PARTY.md` | PSF-2.0 provenance per ported file |
| `planning/master_plan.md`, `planning/README.md` | point at this file |

### 6.7 Explicitly **not** changing

| Item | Why it is avoided |
| --- | --- |
| New bytecodes | §3.1 |
| `bytearray` / `bytes` | §3.2 |
| List/tuple `BINARY_SLICE` | SoA IR indexes; never slices (§5.2) |
| Negative indices | `len-1` in the port; grep-gated (§5.1) |
| `_bi_intern` | LONG_STR content equality already works (§2.1) |
| Growing `RF_DEPTH` | §6.1 adds spill/fill instead; the RF stays 256 entries and the flop count does not move |
| A dedicated stack cache between the RF and dmem | §6.1 S-8: L1D already hits 95–99.6% on the frame region, and per-slot residency costs ~170 Kbit of tables (`attic/pycore_frame_buffer.sv`) |
| LL(1) table generator + grammar tables | Precedence climbing needs neither |
| Module image format / `_bi_load_module` / relocation | The compiler is in the boot image; its output is a handle |
| BIOS | Programs call `compile()` directly |
| Trap → Python exception (exceptions T6) | Syntax errors are already real `raise`s |
| `open` / stdin / console RX | Source is already a heap string |
| Garbage collection | §5.7 policy + caller-driven marks |
| `_bi_code_kind` / string-form `exec`/`eval` | v1 is `eval(compile(...))`; §11 |

---

## 7. Budgets

Measure before you build. The line-to-slot ratio below is derived from the
repository's own audit of `vendor/pycpython` (29 548 lines → ~116 000 logical
code units ≈ **3.9 units/line**; regenerate with
`pycore/tools/measure_pycpython_opcodes.py`). Treat it as ±30%.

| Resource | Capacity | Budget for this work | Source |
| --- | ---: | --- | --- |
| Code ROM | 8 192 slots | unchanged: boot image + ~33 existing builtins (~2 000 slots today, estimated) | `PYCORE_IMEM_BLOCK_COUNT = 16` |
| Code RAM | 32 768 slots | **compiler ≤ 14 000 slots** (≈ 3 500 source lines), leaving ≥ 18 000 for compiled output | `PYCORE_CODE_RAM_BLOCK_COUNT = 64`, `pycore_defs.svh:3661` |
| Heap | ~960 KB (`0x440`–`0xF0000`) | static image + `_PYC_G`; peak working set for a 4 KB source ≈ 250 KB (tokens 96 B each, nodes 192 B each) | `pycore_defs.svh:3098-3099` |
| Register file | 256 entries, ring window | after §6.1: resident working set only; per-frame `nlocals + co_stacksize ≤ ~240` | S-1, S-6 |
| RF spill region | 256 KB / 8 192 entries (new) | ≈ 500–1 000 typical frames before `MEM_FAULT` | S-7 |
| Frame stack | 32 KB / 1 024 descriptors | the binding depth limit after S-5 raises `MAX_CALL_DEPTH_CORE` to match it | `pycore_defs.svh:3100-3101` |
| `int` | signed 64-bit, wraps | line numbers, offsets, packed fields all fit | `architecture.md` |

**First task of the implementation is to replace the estimates in this table
with measurements** (build one image, read `image.meta` and the hex line
counts). If the compiler overruns code RAM, the answer is in order:
(1) shrink `codegen.py` by deferring a tier, (2) raise
`PYCORE_CODE_RAM_BLOCK_COUNT` (it is a parameter, `code_loading.md` §1.2 says
so explicitly), (3) only then consider overlays. Do **not** restart the module
loader for this.

---

## 8. Risks

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | Parser recursion creeps back in and turns into spill traffic | `img_compile_deep_nesting` (A3) golden includes the RF spill count, so it regresses visibly rather than silently |
| R1b | The §6.1 ring rewrite breaks the CALL/RETURN path — the highest-blast-radius change in this plan | Step B's acceptance is the **entire existing image suite unchanged**, plus a directed `tb_regfile`. Land it alone, before any compiler code, so a later failure is never ambiguous between the two |
| R2 | `_bi_exec_globals` namespace inheritance does not hold for some call shape | Prove it in step T0 with `img_compile_ns_inherit` **before** writing the compiler; fallback F-A in §4.2 |
| R3 | Compiler exceeds code RAM | Size report hard-fails (W-8); levers in §7 |
| R4 | Working-set leak exhausts the heap on repeated compiles | `img_compile_repeat` watermark golden; caller mark/release pattern documented; O-2 if it bites |
| R5 | Silent miscompilation | Every differential compares **results** against host CPython *and* against `vendor/pycpython`; never `co_code` |
| R6 | Stale fetch line buffer / L1I after a blit | R-3 is mandatory; `img_code_emit_then_call` emits and immediately calls into the emitted slots |
| R7 | CODC/GIC aliasing after `_bi_heap_release` | R-6 flush rows; `img_compile_release_realloc` compiles, releases, compiles again, checks the second result |
| R8 | Firmware source drifts out of the subset | `test_compiler_subset.py` runs in `make pycore-python-tests` from step A |
| R9 | Emit allowlist drifts from `SUPPORTED_OPS` | `tables.py` is generated from `pycore.json`; CI asserts regeneration is a no-op (W-6) |
| R10 | Licence | PSF-2.0 headers on every ported file, `THIRD_PARTY.md` updated per port |
| R11 | Temptation to "just load PyCPython" | 545 KB generated parser, 455 PEG rule methods, 12 000 recursion limit, 174 classes. CI rejects `vendor/pycpython` appearing in any seeding table |

---

## 9. Sequencing

Each step is done when a **test** is green. T0, A and B are the prerequisites;
do them in order. B and C are the only RTL steps and B must land alone. E–H are
host-side compiler work and can be developed against the stand-ins (W-5) in
parallel with B and C.

| Step | Work | Done when |
| --- | --- | --- |
| **T0** | Pin the three uncertain facts: (a) runtime LONG_STR `==` and ordering, (b) `_bi_exec_globals` namespace inheritance through nested `CALL`, (c) current ROM slot occupancy | `img_str_eq_runtime_long`, `img_compile_ns_inherit`, and a measured §7 table |
| **A** | `test_compiler_subset.py` + `compat` helpers + empty `pycore_firmware/compiler/` | Host test is **red** on `xs[-1]`, `xs[1:]`, `class`, a closure, and an over-cap frame window. Pure host Python, so it can land while B is in flight |
| **B** | **§6.1 S-1…S-9: the RF ring window, spill/fill, and the locals lift.** **Landed** (no compiler code) | The **entire existing image suite passes unchanged**, plus `img_locals_40_uninit` (red on `main` today), `img_locals_64`, `img_rf_deep_recursion`, `img_rf_spill_refill`, `img_rf_thrash`, `img_rf_window_too_big_trap`, `img_rf_spill_oom_trap`, `tb_regfile` |
| **C** | R-1…R-6 + W-4 + W-5 (the code write path and the four builtins). **Landed** | `img_code_new_call`: blit `RESUME; LOAD_SMALL_INT 7; RETURN_VALUE`, `_bi_code_new`, call it, get 7. Plus `img_code_emit_then_call`, `img_code_alloc_oom_trap`, `img_code_write_floor_trap` |
| **D** | W-1, W-2, W-6: seed a two-function toy package into `_PYC_G` and call one from the other. **Landed** | `img_pyc_package_call` |
| **E** | `tables.py` + `lexer.py`. **Landed** | Host: token stream vs CPython `tokenize` on a small corpus. Device: `img_lexer_count` |
| **F** | `parser.py` T1 expressions (iterative) + SoA AST. **Landed** | Host: shape round-trip vs `ast.parse`. Device: `img_parser_tiny_expr`, `img_compile_deep_nesting` |
| **G** | `symtab.py`. **Landed** | Host locals-vs-globals corpus; closures raise cleanly. Device: `img_symtab_locals`, `img_symtab_closure` |
| **H** | `codegen.py` T1 (recursive port, per §5.2 Rule 2) + `assemble.py` + W-3. **Landed** | Host result differential vs CPython for T1 |
| **I** | Wire `compile.py` shim; ship it | **`img_compile_eval_expr` → 3** (A1) |
| **J** | T2 then T3 | `img_compile_exec_roundtrip` (A2) + host corpus |
| **K** | W-8 size report, doc sweep (§6.6), deviation table | `make all-tests` green; report within budget |

Test-harness rules (unchanged, from `README.md`): host tests go in
`pycore/tests/` under `make pycore-python-tests`; device images use
`PYCORE_IMAGE_RUN` / plusargs into the **one shared** `tb_container` binary —
no per-fixture Verilator rebuild. Wire new targets into `pycore-img` and
`pycore-img-two-core`.

---

## 10. Minimum device test set

| Image | Expect |
| --- | --- |
| `img_str_eq_runtime_long` | runtime-built LONG_STR `==` an interned copy is `True` (T0) |
| `img_locals_40_uninit` | 40-local function, unassigned late local → `MEM_FAULT`. **Red on `main`** |
| `img_locals_64` | 64-local function computes correctly |
| `img_rf_deep_recursion` | ~500-frame recursion matches the host golden |
| `img_rf_spill_refill` | spilled locals intact after return |
| `img_rf_thrash` | watermark-straddling call/return ×1000; spill-count golden |
| `img_rf_window_too_big_trap` | oversized frame window → `CALL_FILTER` |
| `img_rf_spill_oom_trap` | unbounded recursion → `MEM_FAULT`, not corruption |
| `img_compile_ns_inherit` | a helper called from an `_bi_exec_globals` frame resolves in the supplied dict (T0) |
| `img_code_new_call` | 7 |
| `img_code_emit_then_call` | blit, then immediately call the blitted slots — catches R-3/R-6 |
| `img_code_alloc_oom_trap` | `MEM_FAULT` |
| `img_code_write_floor_trap` | `MEM_FAULT` writing below the floor |
| `img_code_new_badfield_trap` | `TYPE` |
| `img_pyc_package_call` | cross-function call inside `_PYC_G` |
| `img_lexer_count` | token-count golden |
| `img_parser_tiny_expr` | node-count / checksum golden |
| `img_compile_deep_nesting` | 40 nested parens compile without a trap (A3) |
| `img_symtab_locals` | locals-vs-globals checksum (G) |
| `img_symtab_closure` | 1 — nested load of an enclosing local is `SyntaxError` (G) |
| `img_codegen_t1_expr` | **3** — assemble+call of `"1 + 2"` (H; A1 early, without the compile shim) |
| `img_compile_eval_expr` | **3** (A1) |
| `img_compile_exec_roundtrip` | globals match host CPython (A2) |
| `img_compile_reject_import` | `SyntaxError` (A4) |
| `img_compile_reject_locals` | `SyntaxError` on a function whose window exceeds the §6.1 S-6 cap (D6) |
| `img_compile_mode_trap` | `ValueError` for `"single"` / `flags != 0` (A5) |
| `img_compile_repeat` | heap watermark golden (R4) |
| `img_compile_release_realloc` | second compile after release is correct (R7) |

---

## 11. What comes after

In dependency order, not priority order.

1. **String-form `exec` / `eval`.** Needs `_bi_code_kind` (or `__class__` on
   native tags) to dispatch str vs `CODE_OBJECT`. Thin wrapper over `compile`.
2. **T4 grammar** — `try`/`except`/`finally`, `raise`, comprehensions. The
   runtime already supports all of it; this is codegen work only.
3. **Constant folding** (`ast_preprocess.py` port) — smaller output, closer to
   CPython's `co_code`.
4. **Closures** (`MAKE_CELL` / `LOAD_DEREF` / cells) — the first genuine
   runtime gap, and the one that unblocks the most idiomatic Python.
5. **Split result/scratch heap arenas** (O-2) — only if §5.7's leak bites.
6. **Module loader + relocation** (`code_loading.md` §4) — only when the
   compiler no longer fits the boot image.
7. **BIOS** — a ROM program that initialises and `exec`s a payload.
8. **Self-hosting** — compile `pycore_firmware/compiler/` on device; check
   stage-2 output is byte-identical to stage-1 for the same input. A fixpoint,
   not a demo, and a size problem before it is anything else.

---

## Appendix A — packed formats, in one place

```python
# code slot                (encoding.py:format_imem_slot)
word = (oparg << 8) | opcode                  # bits [63:40] must be 0

# code metadata low 64     (encoding.py:pack_code_metadata)
meta_lo = argcount | (nlocals << 16) | (stacksize << 32) | (kwonly << 48)
# flags argument (field 8 of _bi_code_new)
flags   = (1 if varargs else 0) | (2 if varkw else 0) | (posonly << 2)

# token arrays
tk_a = kind | (col << 8) | (line << 24)
tk_b = start | (end << 32)

# AST arrays
nd_pos = line | (col << 32)
# variable arity: nd_a = kids_start, nd_b = kids_count, kids[] is a flat arena
```

## Appendix B — v1 emit allowlist

Generated into `tables.py` from `pycore/targets/pycore.json`; this list is the
expected content, not a second source of truth.

`RESUME` · `NOP` · `LOAD_CONST` · `LOAD_SMALL_INT` · `LOAD_FAST` ·
`LOAD_FAST_BORROW` · `LOAD_FAST_CHECK` · `STORE_FAST` · `DELETE_FAST` ·
`LOAD_GLOBAL` · `LOAD_NAME` · `STORE_NAME` · `STORE_GLOBAL` · `PUSH_NULL` ·
`BINARY_OP` · `COMPARE_OP` · `IS_OP` · `CONTAINS_OP` · `UNARY_NOT` ·
`UNARY_INVERT` · `UNARY_NEGATIVE` · `TO_BOOL` · `CALL` · `CALL_KW` ·
`LOAD_ATTR` · `STORE_ATTR` · `STORE_SUBSCR` · `DELETE_SUBSCR` ·
`RETURN_VALUE` · `POP_TOP` · `COPY` · `SWAP` · `EXTENDED_ARG` ·
`JUMP_FORWARD` · `JUMP_BACKWARD` · `POP_JUMP_IF_TRUE` · `POP_JUMP_IF_FALSE` ·
`POP_JUMP_IF_NONE` · `POP_JUMP_IF_NOT_NONE` · `NOT_TAKEN` · `GET_ITER` ·
`FOR_ITER` · `END_FOR` · `POP_ITER` · `BUILD_LIST` · `BUILD_TUPLE` ·
`BUILD_MAP` · `BUILD_SET` · `BUILD_STRING` · `LIST_APPEND` · `LIST_EXTEND` ·
`SET_ADD` · `MAP_ADD` · `UNPACK_SEQUENCE` · `UNPACK_EX` · `MAKE_FUNCTION`

**Never emit:** `CACHE` · `LOAD_BUILD_CLASS` · `IMPORT_NAME` · `IMPORT_FROM` ·
`YIELD_VALUE` · `SEND` · `GET_AWAITABLE` · `LOAD_DEREF` · `STORE_DEREF` ·
`MAKE_CELL` · `LOAD_CLOSURE` · `LOAD_SPECIAL` · `SETUP_*` ·
`FORMAT_WITH_SPEC` · `STORE_SLICE` · `LOAD_COMMON_CONSTANT` · `MATCH_*` ·
`LOAD_SUPER_ATTR` · `CALL_INTRINSIC_2`.

## Appendix C — file map for the implementer

| What | Where |
| --- | --- |
| Host oracle (never on device) | `vendor/pycpython/pycpython/` |
| New firmware compiler | `pycore_firmware/compiler/` |
| Public builtin shim | `pycore_firmware/builtins/compile.py` |
| Boot seeding, `SUPPORTED_OPS`, `validate_code_tree` | `pycore/tools/image_from_source.py` |
| Heap object construction | `pycore/tools/heap_image.py` |
| Slot / metadata / tag encoding | `pycore/tools/encoding.py` |
| Exception-table varints | `pycore/tools/exception_table.py` |
| Machine catalog (opcodes, exceptions) | `pycore/targets/pycore.json` |
| CALL FSM / `BI_*` dispatch | `pycore/rtl/pycore_call_fsm.svh` (phase 13) |
| Register file (ring window, S-1/S-6) | `pycore/rtl/pycore_regfile.sv` |
| Frame descriptors (spill/fill quantities) | `pycore/rtl/pycore_frame.sv` |
| Shelved ring-plus-spill prototype — read, do not build | `pycore/rtl/attic/pycore_frame_buffer.sv` |
| Tags, `BI_*` ids, memory map, STRACC helpers | `pycore/rtl/pycore_defs.svh` |
| Core FSM, `code_ram_ptr_r`, STRACC routing | `pycore/rtl/pycore_core.sv` |
| Fetch + line buffer | `pycore/rtl/pycore_fetch.sv` |
| L1I/L1D/L2 + xbar + RAM model | `pycore/rtl/pycore_mem_hier.sv`, `pycore_cache.sv`, `pycore_mem_xbar.sv`, `pycore_ram.sv` |
| CODC / GIC | `pycore/rtl/pycore_codc.sv`, `pycore_gic.sv` |
| Shared testbench | `pycore/tb/tb_container.sv` |
