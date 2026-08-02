# Sets + hash-container / excore split

## Ownership

| Work | Owner | Applies to |
| --- | --- | --- |
| Hash + rich equality (INT/BOOL/FLOAT/STR) | **pycore** | dict, set |
| Linear probe (empty / match / unequal / tombstone) | **pycore** | dict, set |
| Resize / grow | **excore** | list, dict, set |
| Bulk extend / update / merge | **excore** (uncontaminated) | non-empty `LIST_EXTEND`, `SET_UPDATE`, `DICT_UPDATE`, `DICT_MERGE` |
| List element shift on delete | **excore** | `DELETE_SUBSCR` list |
| List append grow | **excore** | `LIST_APPEND` at capacity |

Collisions stay on pycore. Only capacity-changing or O(n) memmove work is
offloaded; pycore waits for `COMPLETED`.

Bulk hash ops (`SET_UPDATE`, `DICT_UPDATE`, `DICT_MERGE`) are offloaded only when
**both** operands are uncontaminated — the excore hashes plain-value keys
directly. A `MUT_COLLEC` handle is *contaminated* (`value[123]`, see `tags.md`)
once an `OBJECT` element/key is inserted; such collections are processed
entirely on pycore (identity hashing) in `pycore_cont_bulk.svh`. `SET_UPDATE`
sources may be `LIST`/`SET`/`DICT` (a dict source inserts its keys); a `TUPLE`
source always takes the pycore path (no contamination bit on tuples).

## Set layout

Sets use a compact object header (no order sidecar) and an element-only
open-addressed table:

```text
obj+0  : { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }

table + i*32 + 0  : element value
table + i*32 + 16 : element tag   // UNINIT=empty; TOMBSTONE=14
```

Handle: `PY_TAG_MUT_COLLEC` with `PY_MUT_SET` and the object address. Deleted
slots use the dedicated `PY_TAG_TOMBSTONE`. Iteration order is undefined
(hash-slot scan).

## Bytecodes

| Op | Path |
| --- | --- |
| `BUILD_SET` | pycore alloc + insert (same-tag + rich numeric eq) |
| `SET_ADD` | pycore probe/insert; load ≥ 2/3 → `SET_GROW` (13) |
| `SET_UPDATE` | uncontaminated + `LIST`/`SET`/`DICT` source → excore `SET_UPDATE` (14); contaminated or `TUPLE` → pycore (`pycore_cont_bulk.svh`) |
| `CONTAINS_OP` on SET | pycore probe + rich eq |
| `DELETE_SUBSCR` on SET | `TYPE` (sets are not subscriptable) |
| `MAP_ADD` | pycore single insert (reuses `STORE_DICT`); grow → `DICT_GROW` (11) |
| `DICT_UPDATE` | uncontaminated → excore `DICT_UPDATE` (19); contaminated → pycore (`pycore_cont_bulk.svh`) |
| `DICT_MERGE` | empty dest → pycore alias; non-empty uncontaminated → excore `DICT_MERGE` (20); contaminated → pycore (`pycore_cont_bulk.svh`) |

## Trap codes

| Code | Name |
| --- | --- |
| 9 | `LIST_GROW` |
| 10 | `LIST_EXTEND` (every non-empty source; empty is a pycore no-op) |
| 11 | `DICT_GROW` |
| 12 | `LIST_DELETE` (mid-list shift-down) |
| 13 | `SET_GROW` |
| 14 | `SET_UPDATE` |
| 19 | `DICT_UPDATE` (grow-to-fit A then insert all of B, overwrite dups) |
| 20 | `DICT_MERGE` (build fresh dict C = A then B, duplicate key → fatal `TYPE`) |
