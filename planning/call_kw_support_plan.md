# CALL_KW / CALL_FUNCTION_EX support plan

**Status:** actionable follow-up (not blocked by missing silicon)  
**Audience:** bytecode / CALL FSM agent  
**Unblocks:** firmware kwargs (`print(sep=)`, `max(key=)`, `sorted(reverse=)`),
varargs (`print(*args)`, `zip(*iterables)`, `max(*xs)`), and general 3.14 call
shapes beyond positional-only

Related:

- Freeze note: `pycore_firmware/builtins/builtins.md`
- Opcode matrix: `pycore/docs/bytecode_support.md`
- Current CALL FSM: `pycore/rtl/pycore_call_fsm.svh`
- Prior builtins plan: `planning/builtins_bytecode_support_plan.md`

---

## 1. Verdict

**Doable now.** The earlier “positional-only freeze” was a milestone scope cut
after LEGB / `BI_LEN` / `TO_BOOL` / `RAISE`, not a fundamental impossibility.

What makes it work is extending the **existing CALL binding path** and a small
set of standard 3.14 opcodes — still **no custom opcodes**.

What makes it non-trivial is that today’s CALL only understands **positional**
`co_argcount` + `co_defaults`, and code objects **do not yet serialize**
`co_varnames` / `co_kwonlyargcount` / kwdefaults. Keyword binding needs those
fields (or an equivalent name table) before `CALL_KW` can target `CODE_OBJECT`.

---

## 2. CPython 3.14 shapes (source of truth)

### 2.1 `CALL_KW` (opcode 55)

Example: `print(1, 2, sep=',', end='!')`

```text
callable, NULL, 1, 2, ',', '!', ('sep', 'end')
CALL_KW  4          # oparg = #positional + #keyword values (not counting names)
```

- TOS = names `TUPLE` of keyword strings (length = #kwargs).
- Below TOS: keyword values in names order, then positional args.
- Free-function NULL sentinel same as `CALL`.
- Stack effect for oparg=4: −6 (pops NULL + 4 values + names, leaves result).

### 2.2 `CALL_FUNCTION_EX` (opcode 4)

`print(*a)`:

```text
callable, NULL, a, NULL
CALL_FUNCTION_EX
```

`print(*a, **d)` (also needs `DICT_MERGE`):

```text
callable, NULL, a, {}, d
DICT_MERGE 1
CALL_FUNCTION_EX
```

- Args object is typically a LIST/TUPLE (or any iterable later).
- Kwargs absent ⇒ `NULL` sentinel; present ⇒ `MUT_DICT`.
- In 3.14 the opcode takes no useful oparg flag in practice; presence of kwargs
  is the NULL-vs-dict tag at TOS.

---

## 3. Gaps in today’s pycore

| Area | Today | Needed |
| --- | --- | --- |
| Decode / validate | `CALL_KW` / `CALL_FUNCTION_EX` deferred; `DICT_MERGE` deferred | Accept + execute |
| Code object layout | metadata = `{stacksize, nlocals, argcount}`; field4 = `co_defaults` only | Add `co_varnames` tuple; pack `kwonlyargcount`; optional `co_kwdefaults` mapping |
| CALL FSM phase 14 | Positional argc in `[min, argcount]` + fill defaults | Bind by name into locals slots; kw-only; unexpected/duplicate kw traps |
| `OBK_BUILTIN` | Positional-only id dispatch | Either ignore/trap kwargs, or per-`BI_*` keyword table, or route to firmware `CODE_OBJECT` |
| Image tooling | Rejects method `__kwdefaults__` | Fold kwdefaults like positional defaults when serializing |

Nothing here requires new ISA inventiveness; it is CALL FSM + image schema work.

---

## 4. Design

### 4.1 Shared binder (recommended)

Implement one **argument binder** used by `CALL`, `CALL_KW`, and (after
expand) `CALL_FUNCTION_EX`:

1. Start with locals slots `0 .. nlocals-1` = UNINIT (or leave unused slots).
2. Place positional args into slots `0 .. n_pos-1`.
3. For each `(name, value)` in kwargs: find index `i` in `co_varnames[0 ..
   argcount+kwonly)` with string equality; if missing → `CALL_FILTER` /
   future TypeError; if already filled → duplicate-kw trap.
4. Fill remaining slots from `co_defaults` / `co_kwdefaults`.
5. If any required slot still UNINIT → missing-arg trap.
6. Enter frame as today (phase 7).

`CALL` becomes “binder with empty kwargs”. That keeps one source of truth.

### 4.2 Code object schema extension

Add fields (suggested layout — keep 32B stride / existing field helpers):

| Field | Contents |
| --- | --- |
| existing 0–4 | entry_slot, co_consts, co_names, metadata, co_defaults |
| **5** | `co_varnames` — `TUPLE` of SHORT_STR/LONG_STR parameter names |
| **6** | `co_kwdefaults` — `MUT_DICT` name→value (empty dict if none) |

Widen metadata pack to include `kwonlyargcount` (and later flags bits for
`*args`/`**kwargs` if/when those parameters are supported).

Image builder (`heap_image.alloc_code` / `image_from_source`) must emit these
for every code object. Until `**kwargs` parameter objects exist, reject
functions with `CO_VARKEYWORDS` / `CO_VARARGS` in validate (or implement as
P2).

### 4.3 `CALL_KW` decode path

1. `is_container` / enter `S_CALL` with a **call mode** flag:
   `CALL_MODE_POS` vs `CALL_MODE_KW`.
2. Phase 0: oparg = total value argc; TOS = names tuple; compute
   `n_kwargs = tuple_size(names)`, `n_pos = oparg - n_kwargs`.
3. Pop names (or keep pointer); validate SHORT_STR/LONG_STR names.
4. Join callable classification (phases 1+) with `call_argcount_r = n_pos`
   and a kwargs descriptor `(names_tuple, values_base)`.
5. For `CODE_OBJECT`: run binder (§4.1).
6. For `OBK_BUILTIN`: see §4.5.
7. For TYPE / BOUND_METHOD: same as today after kwargs bound into the
   effective positional+self layout (or trap kwargs on TYPE ctor until
   `__init__` kw support).

### 4.4 `CALL_FUNCTION_EX`

Split into two milestones:

**EX-A — `*args` only (kwargs TOS = NULL)** — high value, smaller:

1. Require args tag LIST or TUPLE (iterable protocol later).
2. Expand elements onto the operand stack (or into a scratch locals window).
3. Rewrite stack to normal `CALL` layout (`callable, NULL, args...`) with
   `oparg = len(args)`.
4. Jump into existing CALL phase 0/1.

Care: stack overflow if `len(args)` is huge — cap or `CALL_FILTER` /
`MEM_FAULT` with a documented limit.

**EX-B — `*args` + `**kwargs` dict:**

1. Depends on **`DICT_MERGE`** (or accept only a single kwargs dict already
   built without merge). For `f(*a, **d)` CPython emits `DICT_MERGE`, so
   implement `DICT_MERGE` (dict iter + insert, grow via existing
   `DICT_GROW`/excore) as part of this milestone or immediately before.
2. Expand args as in EX-A; treat kwargs dict as the kwargs source for the
   shared binder (iterate insertion-order keys).

### 4.5 `OBK_BUILTIN` + keywords

Do **not** special-case every builtin in the first drop.

| Policy | Behavior |
| --- | --- |
| **Recommended v1** | `CALL_KW` / EX kwargs on `OBK_BUILTIN` → `PY_TRAP_BUILTIN_CALL` or `CALL_FILTER` unless that `BI_*` declares a tiny keyword table |
| **v1 exceptions (optional)** | None initially — force firmware / Python `CODE_OBJECT` for kwargs forms of `max`/`sorted`/`print` |
| **v2** | Per-id tables: e.g. `BI_PRINT` accepts `sep`/`end` as SHORT_STR; `BI_MAX` has no `key=` in HW (Python path) |

Hybrid policy stays: hot positional `BI_*` in CALL FSM; kwargs signatures live
in ROM Python once binder works.

---

## 5. Implementation order

1. **Schema:** serialize `co_varnames` + `kwonlyargcount` + empty/`co_kwdefaults`;
   unit tests on image layout.  
2. **Shared binder** for positional `CALL` (refactor phase 14; behavior
   unchanged for existing tests).  
3. **`CALL_KW` → CODE_OBJECT** (no builtins kwargs yet):
   - images: `def f(a, b=0): ...` called as `f(1, b=2)`; kw-only; missing /
     unexpected / duplicate kw traps.  
4. **`CALL_FUNCTION_EX` EX-A** (`*args`, NULL kwargs) for LIST/TUPLE.  
5. **`DICT_MERGE`** then **EX-B** (`**kwargs`).  
6. Unfreeze firmware signatures in `builtins.md`; implement Python
   `max(..., key=)` / `sorted(..., reverse=)` / `print(..., sep=)` as
   `CODE_OBJECT` ROM entries (or add BI keyword tables).  
7. Docs: `bytecode_support.md`, `architecture.md`, remove positional freeze.

---

## 6. Acceptance checklist

- [ ] `f(1, b=2)` and `f(b=2, a=1)` on a user `def` match CPython results.  
- [ ] Kw-only required/optional + kwdefaults work; positional-only overflow
      into kw-only traps.  
- [ ] Unexpected keyword → distinct trap (prefer `CALL_FILTER` until
      TypeError objects exist).  
- [ ] Duplicate keyword in names tuple → trap.  
- [ ] `g(*[1,2,3])` via `CALL_FUNCTION_EX` equals `g(1,2,3)`.  
- [ ] `g(*[], **{'b': 2})` (after DICT_MERGE path) binds correctly.  
- [ ] Existing positional CALL / defaults / method / TYPE / `BI_*` image
      tests remain green.  
- [ ] `builtins.md` unfreezes kwargs for ROM modules that use them.  
- [ ] Target JSON + `SUPPORTED_OPS` updated; analyzer consistency tests pass.

---

## 7. Explicit non-goals (this plan)

- Full `*args` / `**kwargs` **parameter** objects on user functions
  (`CO_VARARGS` / `CO_VARKEYWORDS`) — can be a fast follow once binder
  exists; not required for `CALL_KW` of ordinary named params.  
- Rich TypeError exception objects (fatal/`CALL_FILTER` is enough initially,
  same as `RAISE_VARARGS` minimum).  
- Native `BI_MAX(key=)` / `BI_PRINT(sep=)` hardware tables (optional v2).  
- Custom opcodes.

---

## 8. Why it was frozen before (for context)

The builtins bytecode milestone prioritized LEGB-B, `BI_LEN` miss path,
`TO_BOOL`, and `RAISE_VARARGS` so firmware could proceed without hacks. Keyword
calls are larger than those items because they touch the **code-object schema
and the CALL binder**, not just a new decode case. That is a sequencing
choice — **not** “blocked until some other subsystem lands,” aside from
`DICT_MERGE` for the `**kwargs` half of `CALL_FUNCTION_EX`.
