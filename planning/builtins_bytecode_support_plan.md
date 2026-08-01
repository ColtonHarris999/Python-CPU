# Builtins → bytecode support plan

**Audience:** agent working on pycore bytecode / CALL / name-lookup support  
**Consumers:** `pycore_firmware/builtins/` (ROM pure-Python builtins)  
**Constraint:** no new custom opcodes — extend standard CPython 3.14 opcodes
and existing `OBK_BUILTIN` / `BI_*` hardware CALL fast paths.

Related:

- Inventory + per-builtin status: `pycore_firmware/builtins/builtins.md`
- Deep blockers: `pycore_firmware/builtins/{compile,eval,exec,open,super,property,ord,chr}.md`
- Opcode matrix: `pycore/docs/bytecode_support.md`
- Object / builtin ids: `pycore/docs/object_model.md`
- Boot + CALL overview: `pycore/docs/architecture.md`

---

## 1. Goal

Unblock finishing firmware builtins by making **name resolution**, **CALL
dispatch**, and a small set of **standard opcodes** match the schematics
below. Hardware keeps fast paths for known container tags; pure Python runs
only on the miss / protocol path (e.g. `obj.__len__()`).

---

## 2. LEGB and the builtins dict (required)

### 2.1 Current hardware (baseline)

Boot record pair 2 holds the module **builtins** dict; `S_BOOT` latches
`builtins_base_r`.

`LOAD_GLOBAL` / `LOAD_NAME` (`CONT_LOAD_GLOBAL`):

1. Resolve `co_names[namei]` (`LOAD_GLOBAL`: `namei = oparg >> 1`;
   `LOAD_NAME`: `namei = oparg`).
2. Probe **globals** dict (`globals_base_r`).
3. On miss (empty slot / full probe / empty table): if builtins not yet
   tried and `builtins_base_r != 0`, probe **builtins** once.
4. Miss in both → `PY_TRAP_MEM_FAULT`.
5. `LOAD_GLOBAL` with `oparg & 1` pushes `NULL` after the value (CPython
   3.14 call prep).

`STORE_NAME` / `STORE_GLOBAL` write **globals only** (never builtins).

This is **G then B** at module scope — not full LEGB yet (no locals dict
for `LOAD_NAME` inside functions).

### 2.2 Target LEGB behavior

| Letter | Store | Load opcode | Required behavior |
| --- | --- | --- | --- |
| **L** | frame locals (fast locals today; mapping for `LOAD_NAME` later) | `LOAD_FAST*` / eventually `LOAD_NAME` | Unchanged for `LOAD_FAST`. Full `LOAD_NAME` must probe a locals mapping when the frame has one (class body / exec — deferred until frame locals exist). |
| **E** | enclosing cells | `LOAD_DEREF` / `LOAD_FROM_DICT_OR_DEREF` | **Out of scope** for this builtins milestone (closures rejected by image tooling). |
| **G** | module globals dict | `LOAD_GLOBAL`, `LOAD_NAME` (module) | Already implemented. |
| **B** | boot-record builtins dict | fallback from G | Already implemented for `LOAD_GLOBAL`/`LOAD_NAME`. **Must remain** the resolution path for `len`, `max`, etc. |

**Bytecode agent deliverable for LEGB (this milestone):**

1. Treat architecture.md as source of truth: document and test
   globals→builtins fallback (fix stale “no builtins fallback” notes).
2. Keep `builtins_base_r` live for the whole run (already latched at boot).
3. Do **not** remove builtins fallback when adding locals to `LOAD_NAME`.
4. Add image/RTL tests: name present only in builtins dict resolves;
   shadowing in globals wins; missing in both traps.

Full function-scope `LOAD_NAME` locals chain is **follow-up**, not required
to finish most firmware builtins (they use `LOAD_FAST` / `LOAD_GLOBAL`).

### 2.3 Builtins dict contents (call schematics)

Each builtins dict value is one of:

| Value kind | Meaning | CALL behavior |
| --- | --- | --- |
| `OBJECT` / `OBK_BUILTIN` + `builtin_id = BI_*` | Native fast-path builtin | CALL FSM tag-dispatch (see §3) |
| `CODE_OBJECT` | Pure-Python / ROM implementation | Normal frame entry (same as user `def`) |
| `OBJECT` / `OBK_TYPE` | Types like `int` | Attribute path for methods (`from_bytes`); constructing via CALL is separate work |

**Hybrid policy (agreed):**

- Prefer **`OBK_BUILTIN` + hardware fast path** for hot, layout-known cases
  (`len`, `range`, `set`, `max`, …).
- Pure-Python `pycore_firmware/builtins/<name>.py` is the **miss / protocol
  path**, not a reimplementation of header reads.
- Example: `BI_LEN` handles list/tuple/dict/set/str in CALL FSM; on
  `OBJECT` instance, resolve and call `__len__` (hardware attr+CALL or
  jump to ROM helper that only does `return obj.__len__()`).

Seeding may evolve from “all `BI_*`” to “`BI_*` for fast paths +
`CODE_OBJECT` for Python-only builtins” without changing the LEGB load
schematic.

---

## 3. CALL schematic for a builtin (e.g. `len(x)`)

CPython 3.14 typical sequence:

```text
LOAD_GLOBAL  (null+name)   # pushes len, then NULL   (oparg & 1)
LOAD_FAST    x             # or LOAD_CONST / …
CALL         1             # argc = 1
```

### 3.1 Resolution

`LOAD_GLOBAL` finds `"len"` in builtins (unless shadowed) → pushes the
`OBK_BUILTIN` handle (or later a `CODE_OBJECT`), then `NULL`.

### 3.2 CALL on `OBK_BUILTIN` (`BI_LEN`) — required hardware behavior

Extend / keep the existing CALL phase-13 dispatch. **Full expected
behavior** for `BI_LEN` (argc must be 1; else CALL filter trap):

| Argument tag / kind | Result | Notes |
| --- | --- | --- |
| `MUT_LIST` | `INT` length from list object header | Existing |
| `TUPLE` | `INT` from tuple handle size | Existing |
| `MUT_DICT` | `INT` from dict `used` | Existing |
| `MUT_SET` | `INT` from set `used` | Existing |
| `SHORT_STR` | `INT` from short-str size field | Existing |
| `LONG_STR` | `INT` from descriptor size | **Add if missing** |
| `PY_TAG_RANGE` | `INT` computed from start/stop/step | **Add** (CPython `len(range)`) |
| `BYTES` / bytearray | `INT` from payload length | When those layouts are live |
| `OBJECT` / `OBK_INSTANCE` | Protocol miss path | Lookup `__len__` on instance dict then MRO; `CALL` with self; require return tag `INT` (or `BOOL`→int); missing → attr error / TypeError trap |
| `OBJECT` / `OBK_TYPE` or other kinds | Type trap | Unless a type defines `__len__` on the type (unusual) |
| `CODE_OBJECT`, `CONTROL`/`None`, numerics, `ITER`, … | Type trap | Not sized |

**Do not** implement `len` in Python by iterating and counting when
`BI_LEN` exists — that bypasses the fast path.

### 3.3 CALL on `CODE_OBJECT` (ROM Python builtin)

Same as today’s user-function CALL: validate argc against `co_argcount` /
defaults; push frame; run bytecode; `RETURN_VALUE` writes result.

Used for builtins with no native id yet (`sum`, `sorted`, …) and for
protocol-only helpers.

### 3.4 Other existing `BI_*` fast paths (keep; extend miss paths later)

| Id | Name | Fast path (summary) | Miss / Python role |
| --- | --- | --- | --- |
| 4 | `MAX` | Two INT/BOOL args → max | Iterable / `key=` forms → Python or later HW |
| 7 | `LEN` | §3.2 | `__len__` protocol |
| 8 | `RANGE` | 1–3 INT/BOOL → `PY_TAG_RANGE` | — |
| 9 | `SET` | 0 args or 1 LIST/TUPLE → set | General iterable → `{*iterable}` / SET_UPDATE |
| 6 | `PRINT` | Trap to excore | — |
| 1–3, 5 | bytearray / from_bytes / to_bytes / list_append | Excore or opcode | — |

---

## 4. Standard bytecodes required (no custom opcodes)

For each opcode: **CPython 3.14 semantics** the firmware relies on, **current
pycore gap**, and **full required behavior** including cases builtins may
not exercise yet.

Priority: **P0** blocks many builtins; **P1** unblocks signatures / errors;
**P2** polish / deferred product features.

### 4.1 P0 — name resolution & CALL (document + harden)

#### `LOAD_GLOBAL` (supported — verify + tests)

- **Stack:** `→ value` or `→ value, NULL` if `oparg & 1`.
- **Behavior:** `namei = oparg >> 1`; load `co_names[namei]`; probe
  globals then builtins (§2); push value; optionally push `NULL`.
- **Errors:** bad name index / missing name → `MEM_FAULT`; bad key tag →
  `TYPE`.
- **Builtin use:** every call to a builtin name from module/function code.

#### `LOAD_NAME` (partial)

- **Stack:** `→ value`.
- **Behavior (required for this milestone):** same globals→builtins probe
  as `LOAD_GLOBAL` without NULL push (module scope).
- **Full CPython (later):** locals mapping → globals → builtins.
- **Errors:** same as `LOAD_GLOBAL` miss.
- **Builtin use:** module-level images; class-body later.

#### `CALL` (supported — extend builtin miss paths)

- **Stack:** `callable, NULL?, arg0..argN-1 → result` (3.14 non-method and
  method layouts as today).
- **Behavior:**  
  - `CODE_OBJECT`: frame entry (existing).  
  - `OBK_BUILTIN`: id dispatch (§3).  
  - `OBK_BOUND_METHOD`: existing bind path.  
  - Other → type / filter trap (until `__call__`).
- **Builtin use:** all builtin invocations.

#### `MAKE_FUNCTION` (supported — defaults only)

- Keep defaults folding; closures/annotations remain rejected.
- **Builtin use:** nested helpers inside firmware modules if whole module
  is imaged.

#### `RETURN_VALUE` (supported)

- Pop TOS, return to caller; for top-level module, existing halt/result
  path.
- If CPython 3.14 emits `RETURN_CONST`, either accept it as
  `LOAD_CONST`+`RETURN_VALUE` equivalent in validate/execute or document
  rewrite — **do not leave image builds failing on `return True`**.

### 4.2 P0 — attribute protocol for miss paths

#### `LOAD_ATTR` (supported — needs `__len__` / method hits)

- **Stack:** `obj → attr` or `obj → attr, self/NULL` when `oparg & 1`.
- **Behavior (full):** existing instance dict + MRO walk; staticmethod
  unwrap (`BI_STATICMETHOD`); method bind rules in `object_model.md`.
- **Required for builtins:** resolving `__len__`, `__bool__`, eventually
  `__iter__` / `__next__` on instances; `fget` when properties exist.
- **Miss:** `PY_TRAP_ATTR_ERROR`.

#### `STORE_ATTR` / `DELETE_ATTR` (supported)

- Instance `__dict__` only today.
- **Builtin use:** limited; `setattr`/`delattr` firmware currently uses
  subscript on `__dict__` because names are runtime strings.

**Note:** runtime-string `getattr(obj, name)` cannot use `LOAD_ATTR`
(compile-time `co_names`). That stays a dict-probe firmware pattern or a
future standard approach — **do not add a custom opcode**; optional later
work is implementing `LOAD_ATTR` from TOS name only if CPython grows an
equivalent (it does not). Keep documenting this limit in `builtins.md`.

### 4.3 P1 — errors and rich signatures

#### `RAISE_VARARGS` (unsupported today — **needed**)

- **oparg:** `0` reraise, `1` raise TOS, `2` raise TOS1 with cause TOS
  (CPython 3.14).
- **Required minimum for builtins:** oparg `1` — TOS is an exception
  instance or class; build/propagate `OBK_EXCEPTION`; until handlers
  exist, fatal `PY_TRAP_RAISE` is acceptable if it is **distinct** and
  testable.
- **Full behavior:** exception table unwind when `SETUP_FINALLY` /
  `PUSH_EXC_INFO` / `RERAISE` land; match CPython 3.14 `dis` docs.
- **Builtin use:** `TypeError`/`ValueError`/`StopIteration` instead of
  `1 % 0` hacks.

#### Exception table / `RERAISE` (deferred but interacts)

- CPython list/set **comprehensions** embed `RERAISE` cleanup.
- **Options (pick one, document in bytecode_support.md):**  
  (A) strip/NOP comprehension exception tables in image tooling when
  bodies cannot raise;  
  (B) implement minimal `RERAISE` + table walk;  
  (C) ban comprehensions in firmware (current approach: `out += [x]`).
- Firmware can live with (C); general programs need (A) or (B).

#### `CALL_KW` (deferred — **needed** for CPython-compatible signatures)

- **Stack:** `callable, NULL?, args..., kwargs_tuple_names, values...`
  per 3.14.
- **Behavior:** bind positional + keyword args to `co_varnames` /
  builtins native form; unknown kw → TypeError/trap.
- **Cases builtins need:** `print(*args, sep=, end=)`, `max(..., key=)`,
  `sorted(..., reverse=)`, `open(..., mode=)`, `int(x, base=)` already
  positional-OK.
- **Cases to implement even if unused immediately:** empty kwargs;
  duplicate kwargs; kw-only params on `CODE_OBJECT`.

#### `CALL_FUNCTION_EX` (deferred — **needed** for varargs builtins)

- **Stack:** `callable, NULL?, *args_tuple, [kwargs_dict]` per 3.14 flags.
- **Behavior:** expand iterable to positional args; optional mapping to
  kwargs; then same as `CALL`/`CALL_KW`.
- **Builtin use:** `max(a,b,c,*)`, `zip(*iterables)`, `print` varargs.
- **Full behavior includes:** empty args tuple; non-iterable args → type
  trap; kwargs dict merge rules.

### 4.4 P1 — container / iteration fidelity

#### `UNPACK_EX` (deferred — **needed** for `tuple(iterable)`)

- **Stack:** iterable → `n = oparg & 0xFF` before, one list, `m = oparg >> 8`
  after.
- **Behavior:** iterate; fill before/after; middle rest as list; wrong
  count → trap/exception.
- **Builtin use:** `return (*lst,)` pattern for `tuple()`.
- **Also required:** starred assignments in general programs.

#### `GET_ITER` / `FOR_ITER` / `POP_ITER` / `END_FOR` (partial — extend)

- **Already:** LIST/TUPLE/STR/DICT/SET/RANGE → hybrid `ITER`.
- **Required additions for builtins:**  
  - `GET_ITER` on `OBJECT`: lookup `__iter__`, call, expect iterator.  
  - `FOR_ITER` on iterator objects with `__next__` (or native iter kinds).  
  - Exhaustion: push nothing, jump, `StopIteration` when exceptions exist.
- **Full behavior (including unused):** invalid iter → `TYPE`; size-change
  during dict/set iter → `TYPE` (existing); generators via `YIELD` = P2.

#### `YIELD_VALUE` / `SEND` / `RETURN_GENERATOR` (deferred — P2)

- Needed for true `enumerate`/`zip`/`map`/`filter` iterators.
- Until then firmware may materialize lists (documented deviation).
- **Full behavior when implemented:** create generator object; suspend
  frame; `SEND`/`NEXT` resume; return → `StopIteration.value`.

#### `TO_BOOL` (supported — **widen**)

- **Today:** INT/BOOL/FLOAT/STR; else `TYPE`.
- **Required for `all`/`any`/`bool`/`if obj`:**  
  - `None` → False  
  - LIST/TUPLE/DICT/SET/RANGE/STR already partially; containers by
    length≠0  
  - `OBJECT`: `__bool__` then `__len__` then True (CPython order)
- **Full behavior:** never leave container truthiness as TYPE trap once
  this lands.

#### `COMPARE_OP` (partial — **widen** for `sorted`/`min`/`max`)

- **Today:** numeric `< <= == != > >=` only.
- **Required:** same-tag `SHORT_STR`/`LONG_STR` ordering (or document
  sorted-of-str as blocked until then).
- **Full behavior:** rich compare `__lt__` on objects = later; keep
  numeric promotion rules.

### 4.5 P1 — slicing & formatting (selective)

#### `BINARY_SLICE` / `STORE_SLICE` (deferred)

- **Behavior:** `obj[start:stop]` / assignment; `None` bounds; step via
  `BUILD_SLICE` + subscript in some 3.14 paths — follow CPython 3.14
  exactly when implemented.
- **Builtin use:** `slice` object consumers; not required for `len`/`sum`.
- Implement with standard opcodes only; bytearray slice may stay excore
  (`PY_TRAP_SLICE`).

#### `BUILD_SLICE` (if emitted)

- **Stack:** `start, stop, step → slice` (arity from oparg).
- Needed when firmware/real code constructs slice objects.

#### `FORMAT_SIMPLE` / `FORMAT_WITH_SPEC` / `BUILD_STRING`

- **FORMAT_SIMPLE:** `value → str(value)` formatting for f-strings.  
- **FORMAT_WITH_SPEC:** `value, spec → format(value, spec)`.  
- **BUILD_STRING:** concatenate N strings on stack.
- **Builtin use:** nicer `str`/`format`/`print` internals; firmware can
  avoid f-strings until these work.
- **Full behavior:** match 3.14 including empty spec and invalid spec
  errors once `RAISE` exists.

### 4.6 P2 — types, descriptors, super, async

| Opcode / feature | Full expected behavior (summary) | Builtin |
| --- | --- | --- |
| `LOAD_BUILD_CLASS` | Push `BUILD_CLASS` callable; dynamic class creation | `type(name, bases, dict)` |
| `LOAD_SUPER_ATTR` | MRO next-class attr load | `super` |
| Descriptor `__get__`/`__set__` on attr path | Invoke property/classmethod | `property`, `classmethod` |
| `GET_AWAITABLE` / async ops | Async iterators | `aiter`/`anext` |
| `IMPORT_NAME` / `IMPORT_FROM` | Module load | not builtins ROM |

These have plan docs under `pycore_firmware/builtins/*.md`; bytecode work
should land `LOAD_SUPER_ATTR` and descriptor hooks before rewriting those
stubs.

---

## 5. Hardware fast paths (not custom bytecode)

Implement as **CALL/`OBK_BUILTIN` dispatch** or **widening existing opcode
FSMs** — never as new opcodes outside CPython’s set.

| Fast path | Where | Behavior |
| --- | --- | --- |
| `BI_LEN` | CALL FSM | §3.2 table |
| `BI_MAX` | CALL FSM | Keep 2-arg INT/BOOL; optional later N-arg |
| `BI_RANGE` | CALL FSM | Keep 1–3 arg → `PY_TAG_RANGE` |
| `BI_SET` | CALL FSM | Keep empty / LIST / TUPLE; else trap or SET_UPDATE |
| `BI_PRINT` | CALL → excore | Unchanged |
| Truthiness | `TO_BOOL` | §4.4 widen |
| Str compare | `COMPARE_OP` | §4.4 widen |
| `ORD`/`CHR` | Prefer new **`BI_ORD` / `BI_CHR`** ids (same OBK_BUILTIN pattern), not opcodes | Decode/encode one-char SHORT_STR |

Image seeding: add builtins dict entries when new `BI_*` ids ship; ROM
Python remains the protocol fallback.

---

## 6. What the builtins agent needs from you (acceptance)

Ship / verify the following so firmware work can continue without hacks:

1. **LEGB-B tests:** `LOAD_GLOBAL`/`LOAD_NAME` → builtins dict (shadowing,
   miss, NULL bit).
2. **`BI_LEN` miss path:** `OBJECT` + `__len__` → INT (or clear trap).
3. **`LONG_STR` / `RANGE` length** on `BI_LEN` if not already done.
4. **`RAISE_VARARGS` (oparg 1)** fatal-but-correct exception raise.
5. **`TO_BOOL`** for `None` + containers.
6. **Policy for comprehension `RERAISE`** (strip vs implement) documented
   in `bytecode_support.md`.
7. **`CALL_KW` + `CALL_FUNCTION_EX`** or an explicit “firmware stays
   positional-only” freeze in `builtins.md` if deferred again.
8. **`UNPACK_EX`** or accepted alternative for `tuple(iterable)`.
9. **`RETURN_CONST`** (or rewrite) so `return True/False/None` images
   validate on 3.14.
10. Docs in `pycore/docs/` updated to match shipped behavior (no
    contradictory “no builtins fallback”).

---

## 7. Suggested implementation order

1. Doc sync + builtins-fallback tests (quick win; behavior mostly exists).  
2. `BI_LEN` extensions (`LONG_STR`, `RANGE`, `__len__` miss).  
3. `TO_BOOL` widen + tests (`all`/`any`/`bool`).  
4. `RAISE_VARARGS` minimum + replace firmware `% 0` where touched.  
5. `RETURN_CONST` / validate fix.  
6. Comprehension exception policy.  
7. `UNPACK_EX`.  
8. `CALL_FUNCTION_EX` then `CALL_KW`.  
9. `GET_ITER`/`FOR_ITER` object protocol.  
10. Descriptors / `LOAD_SUPER_ATTR` / `BI_ORD`/`BI_CHR`.

---

## 8. Out of scope (do not invent opcodes for these)

- Host `compile()` / full `eval`/`exec` of source (§ plans in firmware).  
- Filesystem `open`.  
- Async.  
- Custom `LEN` / `TAG_OF` / `LOAD_ATTR_DYNAMIC` opcodes — use `BI_*`,
  `TO_BOOL`/`COMPARE_OP` widening, and dict/attr FSMs instead.
