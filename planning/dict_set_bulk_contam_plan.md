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
      grow + overwrite; value=324). Contaminated source → pycore path is a
      documented gap (routes to `TYPE`).
- [x] `DICT_MERGE` non-empty dest works via excore trap 20 (`img_dict_merge`
      `f(**{...}, **{...})`; value=321); duplicate key → fatal `TYPE`.
- [x] `SET_UPDATE` still green for `{*s, *xs}` (`img_set_update`, value=3);
      routing respects contam; excore extended to accept `DICT` sources.
- [x] `CALL_FUNCTION_EX` kwargs path still green (`img_call_function_ex_kw`, plus
      the empty-dest alias in `img_dict_merge`).
- [x] Docs (`bytecode_support.md`, `tags.md`, `set_excore.md`, `architecture.md`,
      `firmware_build.md`, `pycore.json` target) + `SUPPORTED_OPS` +
      `pycore-python-tests` / `excore-test` / two-core img suite green.

### Known gaps

- Contaminated (OBJECT-key/element) `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE`
  and `TUPLE`-source `SET_UPDATE` are routed to a `TYPE` trap rather than a full
  pycore bulk rehash loop. The uncontaminated excore fast paths — the common
  case for value/string keys — are complete and tested. The RTL bulk-scan
  phase codes (`CP_BULK_*`) are reserved for that follow-up.
- `MAP_ADD` with an OBJECT key that also needs a table grow relies on the shared
  `DICT_GROW` excore path (OBJECT keys hash by identity in pycore probe).
