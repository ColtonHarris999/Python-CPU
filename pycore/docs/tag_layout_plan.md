# PyCore Tag Layout Plan

Plan for restructuring the 4-bit primary tag space: group sparse control
sentinels, collapse mutable collection handles behind one secondary-decoded
tag, rename `PTR` → `ITER`, and add first-class room for `RANGE`, immutable
`BYTES`, and related structures.

This is a design plan only — no RTL migration in this change.

---

## Goals

1. **`CONTROL` (`0000`)** — group `UNINIT`, `NONE`, `NULL` (and related
   sentinels) behind one primary tag with an inline control id.
2. **`MUTABLE`** — one primary tag for mutable collection handles (`LIST`,
   `DICT`, `SET`, `BYTEARRAY`, …) with an inline collection kind.
3. **`ITER`** — rename today’s `PTR` so the encoding matches its real use
   (hybrid iterators from `GET_ITER` / `FOR_ITER`).
4. **New first-class types** — `RANGE`, immutable `BYTES`, and a small set of
   reserved sockets that fit the freed primary slots.
5. **Keep the 4-bit primary tag width** — do not widen `PYCORE_TAG_WIDTH`
   (RF, dmem packing, every hex image, every TB).

Non-goals for this redesign:

- Widening INT beyond the 64-bit fast path.
- Generic `__iter__` / user iterator protocol.
- Moving `BOOL` under `CONTROL` (ALU / compare / truthiness want a 1-cycle
  primary tag).

---

## Proposed primary tag map

| Primary | Name | Role |
| --- | --- | --- |
| `0000` | `CONTROL` | Secondary-decoded sentinels (`UNINIT` / `NONE` / `NULL` / …) |
| `0001` | `INT` | Signed 64-bit fast path (unchanged) |
| `0010` | `FLOAT` | IEEE754 binary64 in `value[63:0]` (unchanged) |
| `0011` | `BOOL` | `value[0]` (unchanged; stays first-class) |
| `0100` | `ITER` | Hybrid iterator state (today’s `PTR` payload) |
| `0101` | `TUPLE` | Immutable sized ref `{size, addr}` |
| `0110` | `SHORT_STR` | Inline UTF-8 (≤15 B) |
| `0111` | `LONG_STR` | Heap/string-mem `{size, addr}` |
| `1000` | `MUTABLE` | Secondary-decoded mutable collection handle |
| `1001` | `OBJECT` | General heap object; `ob_head` kind decode |
| `1010` | `RANGE` | Inline range descriptor (see below) |
| `1011` | `BYTES` | Immutable bytes handle / short-bytes (see below) |
| `1100` | `CODE` | Code-object handle (today’s `CODE_OBJECT`) |
| `1101` | `FROZENSET` | Reserved immutable set handle (or leave reserved) |
| `1110` | *(free)* | Reserved — candidate: `COMPLEX`, `SLICE` object, etc. |
| `1111` | *(free)* | Reserved |

### Mapping from today’s tags

| Today | Becomes |
| --- | --- |
| `UNINIT` (`0000`) | `CONTROL` + `CTL_UNINIT` |
| `NONE` (`1111`) | `CONTROL` + `CTL_NONE` |
| `NULL` (`1110`) | `CONTROL` + `CTL_NULL` |
| `PTR` (`0100`) | `ITER` (same encoding value, new name) |
| `LIST` / `DICT` / `SET` | `MUTABLE` + `MUT_LIST` / `MUT_DICT` / `MUT_SET` |
| `OBJECT` + `OBK_BYTEARRAY` | Prefer `MUTABLE` + `MUT_BYTEARRAY` (see notes) |
| `FRAME_OBJECT` | Dropped as a primary; frames stay in the frame manager / dmem stack |
| `CODE_OBJECT` | `CODE` (rename only) |
| `TOMBSTONE` (`== DICT`) | `CONTROL` + `CTL_TOMBSTONE` (**must change**) |

---

## Secondary decode layouts

### `CONTROL` — `ptag = 0000`

Empty / sentinel payloads. Discriminant in the low nibble (rest zero):

```text
value[127:4] = 0
value[3:0]   = ctl_id

ctl_id:
  0  CTL_UNINIT      unbound local / empty dict-set slot
  1  CTL_NONE        Python None
  2  CTL_NULL        CPython self_or_null call sentinel
  3  CTL_TOMBSTONE   deleted dict/set key slot (replaces DICT-alias)
  4  CTL_ELLIPSIS    reserved (Python Ellipsis) — optional later
  5  CTL_NOTIMPLEMENTED  reserved — optional later
```

**Helpers (RTL + Python):**

```text
pycore_is_control(tag) / is_none(entry) / is_null(entry) / is_uninit(entry)
pycore_make_none() / make_null() / make_uninit() / make_tombstone()
```

**Decode impact:**

- `PUSH_NULL`, `DELETE_FAST`, `POP_JUMP_IF_NONE`, call-filter NULL checks,
  dict empty/tombstone probes all move from primary-tag compares to
  `tag==CONTROL && ctl_id==…`.
- Combinational cost is one extra nibble compare — acceptable on these paths.

### `MUTABLE` — `ptag = 1000`

Addr-only handles that today waste `value[127:64]`:

```text
value[127:124] = mut_kind     // secondary decode
value[123:64]  = 0            // reserved (must be zero on write)
value[63:0]    = obj_addr     // 32-bit used on v1 bus; upper zero

mut_kind:
  0  reserved / invalid
  1  MUT_LIST
  2  MUT_DICT
  3  MUT_SET
  4  MUT_BYTEARRAY
  5  MUT_DEQUE          // reserved socket
  6  MUT_ORDERED_DICT   // reserved socket (if ever distinct from DICT)
```

In-dmem object layouts for LIST / DICT / SET stay as they are today
(header + buffer/table). Only the **handle tag** changes.

**Helpers:**

```text
pycore_is_list(entry)  := tag==MUTABLE && mut_kind==MUT_LIST
pycore_is_dict(entry)  := tag==MUTABLE && mut_kind==MUT_DICT
...
pycore_mutable_addr(value) / pycore_mutable_kind(value)
```

All `CONT_*` / decode sites that today say `tag == PY_TAG_LIST` become helper
calls so a future layout tweak is one place.

### `OBJECT` — stays third-level (dmem `ob_head`)

Keep for things that need a heap header and heterogeneous fields:

| `OBK_*` | Notes after migration |
| --- | --- |
| `INSTANCE` | unchanged |
| `TYPE` | unchanged |
| `BOUND_METHOD` | unchanged |
| `BUILTIN` | unchanged |
| `EXCEPTION` | unchanged |
| `BYTEARRAY` | **migrate off** → `MUTABLE`/`MUT_BYTEARRAY` |
| *(future)* | `GENERATOR`, `MODULE`, … |

`OBJECT` means “slow path / read `ob_head`.” Mutable collections that the
core already special-cases should not pay that read.

### `ITER` — rename of `PTR` (`0100`)

Payload unchanged:

```text
[127:120] magic 8'hA5
[119:116] kind   (LIST / TUPLE / RANGE / STR / BYTES / HEAP_ITER)
[115:96]  aux
[95:64]   index / current
[63:32]   size / stop
[31:0]    addr / object
```

Update kind sockets:

| Kind | Source | Notes |
| --- | --- | --- |
| `LIST` | live | re-read header each step |
| `TUPLE` | live | captured length |
| `RANGE` | **implement with `RANGE` tag** | aux=step, index=current, size=stop; addr unused / start |
| `STR` | reserved | walk `SHORT_STR`/`LONG_STR` |
| `BYTES` | **new reserved** | walk immutable bytes |
| `HEAP_ITER` | reserved | dict/set views later |

Legacy `MEM_LOAD_PTR` / `MEM_STORE_PTR` test opcodes keep working against an
`INT`/`CONTROL`-free address entry, or are retargeted to a dedicated test
harness — they must **not** require the `ITER` tag.

---

## New / promoted structures

### `RANGE` (`1010`) — inline, no heap

CPython `range(start, stop, step)` is small and immutable. Pack it in the
entry so `GET_ITER` is cheap:

```text
value[127:96] = start   // signed 32-bit (v1)
value[95:64]  = stop
value[63:32]  = step    // ≠ 0; default 1
value[31:0]   = 0
```

`GET_ITER` on `RANGE` → `ITER` kind `RANGE` with current=`start`, stop, step.
`FOR_ITER` does index arithmetic only (no dmem). Overflow / zero-step →
`TYPE` or `VALUE` trap policy TBD (recommend `TYPE` for step 0).

Why first-class (not under `OBJECT`): allocator targets and loops use `range`
heavily; an `ob_head` round-trip would be pure overhead.

### `BYTES` (`1011`) — immutable bytes

Mirror the string split, but binary and distinct from `str`:

**Short path (inline), when `len ≤ 15`:**

```text
Same packing as SHORT_STR:
  size[127:124], data bytes, flags[3:0]=0
Primary tag = BYTES (not SHORT_STR) so type(x) is bytes, not str.
```

**Long path:**

```text
value[127:64] = size
value[63:0]   = buf_addr   // dmem or string_mem bank — pick one bank and document
```

Recommendation: store long `BYTES` payloads in **dmem** (same as
`BYTEARRAY` buffers), not `string_mem`, so `bytearray` ↔ `bytes` copies and
excore slice helpers share one address space. `LONG_STR` stays on
`string_mem` (UTF-8 / concat path).

Ops to plan (M-ladder follow-on):

- construct from short literals / `bytes(...)` builtin
- `len`, subscript, slice → excore when O(n)
- `==` / `!=` (same-tag), ordering traps like strings
- `bytearray(bytes)` / `bytes(bytearray)` conversions

### `MUTABLE` / `MUT_BYTEARRAY`

Promote `OBK_BYTEARRAY` out of `OBJECT` into `MUTABLE`:

- Handle: `{MUTABLE, MUT_BYTEARRAY, addr}`
- Object layout unchanged (`length`, `buf_addr`, `capacity`)
- `BINARY_SLICE` / `STORE_SLICE` / `len` dispatch on `mut_kind` without
  `ob_head`

### `FROZENSET` (`1101`) — reserved

Immutable set. Layout can clone SET tables with a frozen flag, or share SET
dmem layout under a different primary so mutation ops type-trap. Leave
unimplemented until SET coverage is solid; reserve the tag so we do not paint
ourselves into a corner.

### Intentionally not added as primaries (yet)

| Idea | Where it lives instead |
| --- | --- |
| `COMPLEX` | free `1110` later, or `OBJECT` |
| `SLICE` object | `OBJECT` or free tag; slice *ops* may stay excore traps |
| `FRAME` handle | keep frame manager; no Python-visible frame objects in v1 |
| `DEQUE` | `MUT_DEQUE` socket under `MUTABLE` |
| `MEMORYVIEW` | `OBJECT` (buffer protocol is heavy) |

---

## Full entry layout cheat sheet

```text
CONTROL    { ptag=0000, ctl_id[3:0], zeros }
INT        { ptag=0001, signext64 || i64 }
FLOAT      { ptag=0010, 64'b0, f64 }
BOOL       { ptag=0011, zeros, b }
ITER       { ptag=0100, magic, kind, aux, index, size, addr }
TUPLE      { ptag=0101, size64, addr64 }
SHORT_STR  { ptag=0110, size4, bytes120, flags4 }
LONG_STR   { ptag=0111, size64, addr64 }
MUTABLE    { ptag=1000, mut_kind4, zeros, addr64 }
OBJECT     { ptag=1001, zeros, addr64 } + ob_head in dmem
RANGE      { ptag=1010, start32, stop32, step32, 0 }
BYTES      { ptag=1011, short packing  OR  size64+addr64 }
CODE       { ptag=1100, zeros, addr64 }
FROZENSET  { ptag=1101, zeros, addr64 }   // reserved
free       { ptag=1110 / 1111 }
```

---

## Critical design notes (read before implementing)

### 1. Tombstones cannot alias `DICT` anymore

Today `PY_TAG_TOMBSTONE == PY_TAG_DICT` because dicts are not valid keys.
After `DICT` becomes `MUTABLE`+`MUT_DICT`, that alias is wrong (a deleted slot
would look like a live mutable handle if mis-read as a value).

**Required:** `CTL_TOMBSTONE` under `CONTROL`. Update dict/set probe, insert,
delete, and hash-key-ok checks. Empty slots stay `CTL_UNINIT`.

### 2. Hot-path cost is a nibble, not a dmem read

`MUTABLE` secondary decode is combinational on the entry. Do **not** fold
LIST/DICT/SET into `OBJECT`/`ob_head` — that would add a memory cycle to
`BINARY_SUBSCR` / `LIST_APPEND` / dict probe.

### 3. Image + hex breakage surface

Every committed DMEM/IMEM fixture that embeds tag nibbles in entries must be
regenerated (`encoding.py`, heap builders, hand fixtures, type-pair tables,
`tb_exec` / `tb_tag_decode`). Treat encoding constants as the single source of
truth; generators must import them (no duplicated magic numbers).

### 4. Keep `BOOL` first-class

Putting `True`/`False` under `CONTROL` would slow `AND`/`OR`/`COMPARE` tag
routing and blur “sentinel” vs “numeric-adjacent”. `CONTROL` is for
non-values / protocol sentinels only.

### 5. `RANGE` vs `ITER` kind `RANGE`

Both exist:

- `RANGE` tag = the range **object** (iterable).
- `ITER` kind `RANGE` = the iterator state produced by `GET_ITER`.

Do not store live iterator cursors in the `RANGE` entry itself.

### 6. `BYTES` vs `BYTEARRAY` vs `LONG_STR`

| Type | Mutability | Tag | Storage |
| --- | --- | --- | --- |
| `str` short/long | immutable | `SHORT_STR` / `LONG_STR` | inline / string_mem |
| `bytes` | immutable | `BYTES` | inline or dmem buffer |
| `bytearray` | mutable | `MUTABLE`/`MUT_BYTEARRAY` | dmem object + buffer |

Shared compare/slice microcode can key off a `pycore_is_bytes_like` helper,
but tags stay distinct for `type()` and store paths.

### 7. Call / boot paths

- `CODE` stays first-class (call filter + boot walker check tag without
  `mut_kind` / `ob_head`).
- Boot record pair types unchanged in *role* (code / globals dict / builtins
  dict); only the dict handle encoding becomes `MUTABLE`+`MUT_DICT`.

### 8. Compatibility shims during migration

Provide temporary aliases in `pycore_defs.svh` / `encoding.py`:

```text
PY_TAG_PTR  = PY_TAG_ITER          // delete after sweep
PY_TAG_LIST = /* illegal — force helper use */
```

Prefer breaking hard at compile time (remove old locals) over silent dual
acceptance in RTL, except maybe one release of image tooling that can *write*
new tags while tests still understand old hex (read path dual-decode) if
rollout needs it. Recommendation: **single cutover** with fixture regenerate
in the same PR series — dual-read is easy to leave forever.

---

## Implementation milestones (suggested)

### T0 — Spec lock

- Land this document.
- Freeze primary map + `ctl_id` / `mut_kind` numbers.
- List every `PY_TAG_*` compare site (RTL, TB, Python tools).

### T1 — Encoding + helpers only

- Update `pycore_defs.svh` and `encoding.py`.
- Add `pycore_is_*` / `make_*` helpers; no behavior change yet if aliases map
  old values… **or** big-bang with T2.

### T2 — `ITER` rename + `CONTROL` cutover

- Rename `PTR` → `ITER` everywhere.
- Implement `CONTROL` sentinels; move `NONE`/`NULL`/`UNINIT`/`TOMBSTONE`.
- Fix dict/set tombstone logic.
- Regenerate fixtures; repair `POP_JUMP_IF_NONE`, `PUSH_NULL`, unbound locals.

### T3 — `MUTABLE` cutover

- Collapse `LIST`/`DICT`/`SET` handles.
- Move `BYTEARRAY` from `OBK_*` to `MUT_BYTEARRAY`.
- Update container FSM dispatch and image builders.

### T4 — `RANGE` + `ITER` kind `RANGE`

- Tag + `GET_ITER` / `FOR_ITER` paths.
- Image tests: `sum(range(...))`, empty range, negative step.

### T5 — `BYTES`

- Short + long encodings; `len` / subscript / `==`.
- Wire `allocator_bytes.py` onto `BYTES`/`BYTEARRAY` (M8 continuation).

### T6 — Reserve / optional

- `FROZENSET` socket or document as free.
- Sweep dead `FRAME_OBJECT` references.
- Update `architecture.md`, `object_model.md`, `bytecode_support.md`.

---

## Test plan (when implementing)

- Unit: `tb_tag_decode`, `tb_exec`, type-pair matrix rebuilt for new primaries.
- Container: all LIST/DICT/SET/append/extend/excore tests (fixture regen).
- Control: `PUSH_NULL`, unbound local, `POP_JUMP_IF_NONE`, dict delete
  tombstone probe.
- Iter: existing FOR_ITER list/tuple + new range loops.
- Bytes: short/long equality, `bytearray` interaction, allocator_bytes.
- Full `make all-tests` / CI (timeout already 90 minutes).

---

## Summary diagram

```text
                4-bit primary
                     │
     ┌───────────────┼──────────────────┐
     │               │                  │
 CONTROL          MUTABLE            OBJECT
 ctl_id            mut_kind           ob_head (dmem)
 UNINIT            LIST               INSTANCE
 NONE              DICT               TYPE
 NULL              SET                BOUND_METHOD
 TOMBSTONE         BYTEARRAY          BUILTIN
                   (DEQUE…)           EXCEPTION

 First-class leaves (no secondary tag):
   INT  FLOAT  BOOL  ITER  TUPLE  SHORT_STR  LONG_STR
   RANGE  BYTES  CODE  (FROZENSET)  (free×2)
```
