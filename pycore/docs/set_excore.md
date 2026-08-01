# Sets + hash-container / excore split

## Ownership

| Work | Owner | Applies to |
| --- | --- | --- |
| Hash + rich equality (INT/BOOL/FLOAT/STR) | **pycore** | dict, set |
| Linear probe (empty / match / unequal / tombstone) | **pycore** | dict, set |
| Resize / grow | **excore** | list, dict, set |
| Bulk extend / update | **excore** | non-empty `LIST_EXTEND`, `SET_UPDATE` |
| List element shift on delete | **excore** | `DELETE_SUBSCR` list |
| List append grow | **excore** | `LIST_APPEND` at capacity |

Collisions stay on pycore. Only capacity-changing or O(n) memmove work is
offloaded; pycore waits for `COMPLETED`.

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
| `SET_UPDATE` | always excore `SET_UPDATE` (14) — bulk like LIST_EXTEND |
| `CONTAINS_OP` on SET | pycore probe + rich eq |
| `DELETE_SUBSCR` on SET | `TYPE` (sets are not subscriptable) |

## Trap codes

| Code | Name |
| --- | --- |
| 9 | `LIST_GROW` |
| 10 | `LIST_EXTEND` (every non-empty source; empty is a pycore no-op) |
| 11 | `DICT_GROW` |
| 12 | `LIST_DELETE` (mid-list shift-down) |
| 13 | `SET_GROW` |
| 14 | `SET_UPDATE` |
