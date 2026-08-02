# DICT_MERGE / DICT_UPDATE / MAP_ADD / SET_UPDATE + contamination bit

**Status:** implementing on `cursor/dict-set-bulk-9270`  
**Base:** `bytecode_support`

## 1. Contamination bit

Lives on **MUT_COLLEC** (and reserved **FROZENSET**) handle value, immediately
after the kind nibble:

```text
value[127:124] = kind
value[123]     = contaminated   ← NEW
value[122:64]  = 0
value[63:0]    = object addr
```

- Set whenever an **OBJECT**-tagged **key** (dict) or **element** (set/list)
  is inserted at create or modify time.
- Dicts: contamination tracks **keys only** (values ignored).
- Tuples have no spare bits — pycore must scan tuple elements when feeding
  them into a set / hashable insert.
- On bulk update/merge, if the source is contaminated, set the dest/
  result contamination bit **before** walking elements (minimize traps).

Helpers: `pycore_mut_contaminated` / `pycore_mut_value(kind, addr, contam)` /
`make_mut(..., contaminated=False)`.

## 2. MAP_ADD (always pycore)

Single key/value insert into the map `oparg` deep. Reuse STORE_DICT probe/
insert/grow path; set contamination if key is OBJECT. No excore for the
happy path (DICT_GROW still applies).

## 3. DICT_UPDATE — `A.update(B)`

Stack: dest `A` at `tos-1-oparg`, source `B` at TOS; pop source.

`resize = needs_grow(used(A)+used(B), slots(A))` (same 2/3 rule family).

```
if resize:
  alloc new table for A sized ~ used(A)+used(B) (pow2)
  if !contam(A) && !contam(B):
    ONE excore trap: rehash A + insert all of B + assign table
  else:
    if contam(A): pycore rehash A into new table; else ONE excore rehash A
    if contam(B): pycore insert B; else ONE excore insert B
      (combine into a single trap whenever both halves need excore)
    if contam(B): set contam(A)
else:
  if contam(B):
    set contam(A); pycore insert B
  else:
    ONE excore insert B
```

Overwrite on duplicate keys (update semantics).

## 4. DICT_MERGE — build combined dict

CPython stack effect −1 (leave dest, pop source). Implementation:

```
C = new dict(capacity ~ used(A)+used(B))
if !contam(A) && !contam(B):
  ONE excore trap: merge A then B into C (error on duplicate key)
else:
  if contam(A) or contam(B): set contam(C)
  merge A into C (pycore if contam(A) else excore)
  merge B into C (pycore if contam(B) else excore)
    — still at most ONE excore trap total
replace A’s RF slot with C; pop B
```

Duplicate keys → `CALL_FILTER` / TYPE (until TypeError objects exist).

## 5. SET_UPDATE — `A.update(iterable B)`

`col(B)` = LIST / SET / DICT / TUPLE (fast path, no iterator protocol).  
`con(x)` = has contamination bit and it is 1.  
Tuples: always scanned on pycore (no contam bit).

```
resize = needs_grow(used(A)+size(B), slots(A))
if resize:
  alloc new table for A
  if !con(A) && col(B) && !con(B):
    ONE excore trap: everything
  elif !con(A):
    excore rehash A into new table (ONE trap)
    then pycore inserts B (iterator or col fast-path)
  else:
    pycore rehash A into new table
    if !col(B): pycore iterate B
    elif !con(B): excore insert B (ONE trap)
    else: pycore insert B
else:  # analogous, at most one excore trap
  ...
```

## 6. Trap codes

| Code | Name | When |
| --- | --- | --- |
| 14 | `SET_UPDATE` | (existing) uncontam set bulk path |
| 19 | `DICT_UPDATE` | uncontam dict update bulk |
| 20 | `DICT_MERGE` | uncontam dict merge bulk |

Discriminate sub-ops via mailbox `instr` opcode when one trap does
“rehash A only” vs “full update”.

## 7. Acceptance

- [x] Contamination bit (`value[123]`) set on OBJECT key/element insert in
      `BUILD_MAP`/`BUILD_SET`/`SET_ADD`/`STORE_DICT`/`MAP_ADD`/`LIST_APPEND`;
      folded into the handle written back to the container's RF slot.
- [x] `MAP_ADD` image (`img_map_add`, hand-shaped via `MAP_ADD_SEQ` inject to
      avoid the dict-comprehension `RERAISE`); value=15, drives `DICT_GROW`.
- [x] `DICT_UPDATE` uncontam → one excore trap 19 (`img_dict_update`, `{**a,**b}`
      grow + overwrite; value=324). Contaminated (OBJECT-key) source → full pycore
      grow+rehash+order-copy+insert engine (`pycore_cont_bulk.svh`), verified by
      `img_dict_update_obj` (seeded instance keys; grow + duplicate-overwrite;
      value=0xa23e / 41534).
- [x] `DICT_MERGE` non-empty dest works via excore trap 20 (`img_dict_merge`
      `f(**{...}, **{...})`; value=321); duplicate key → fatal `TYPE`. Contaminated
      path builds a fresh `C = merge(A, B)` in pycore reusing the same insert
      engine (dup key → `TYPE`); unreachable via current tooling (kwargs keys are
      always strings) but implemented for completeness.
- [x] `SET_UPDATE` still green for `{*s, *xs}` (`img_set_update`, value=3);
      routing respects contam; excore extended to accept `DICT` sources.
      `TUPLE`-source / contaminated `SET_UPDATE` now owned by pycore
      (grow+rehash+element inserts, dup-skip), verified by `img_set_update_tuple`
      (`{*t, *u}` with a tuple `u` crossing the grow threshold; value=0x21 / 33).
- [x] `CALL_FUNCTION_EX` kwargs path still green (`img_call_function_ex_kw`, plus
      the empty-dest alias in `img_dict_merge`).
- [x] Docs (`bytecode_support.md`, `tags.md`, `set_excore.md`, `architecture.md`,
      `firmware_build.md`, `pycore.json` target) + `SUPPORTED_OPS` +
      `pycore-python-tests` / `excore-test` / two-core img suite green.

### Bulk contaminated paths (now implemented)

Contaminated (OBJECT-key/element) `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE`
and every `TUPLE`-source `SET_UPDATE` are now owned end-to-end by pycore in
`pycore/rtl/pycore_cont_bulk.svh` (included from `pycore_core.sv`): optional
grow → rehash of the destination into a larger table (dict also copies the order
sidecar) → fold every source element in via a shared probe/insert sub-FSM
dispatched by `container_bulk_mode_r` (REHASH vs INSERT). The uncontaminated
LIST/SET/DICT fast paths still take a single excore trap (unchanged). The
`cont_rs*_contam` signals only read the contamination bit when the operand tag is
`MUT_COLLEC`, so non-collection operands can never be mis-read as contaminated.

### Remaining notes

- `MAP_ADD` with an OBJECT key that also needs a table grow keeps using the
  shared `DICT_GROW` excore path. This is correct, not a gap: excore's `hash_key`
  hashes an OBJECT (unknown-tag) key by its low 32 value bits and `keys_rich_eq`
  falls back to a bit compare — i.e. identity hash/eq, matching pycore's
  `pycore_dict_key_hash` OBJECT `default` (`value[31:0]`) and identity probe. The
  dict object base address (and therefore the contaminated handle value) is
  unchanged across a grow, so contamination is preserved on the returned handle.
  A pycore-native `MAP_ADD` grow would only save the core crossing; it is left as
  a future optimization because `MAP_ADD_SEQ` (the only way to hand-shape a
  `MAP_ADD` run in an image) emits `LOAD_SMALL_INT` keys and so cannot exercise —
  or regression-test — an OBJECT-key grow.
