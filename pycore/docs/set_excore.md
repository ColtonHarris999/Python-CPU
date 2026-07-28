# Sets + revised hash-container / excore split

## Revised ownership (post scoreboard-prep)

| Work | Owner | Applies to |
| --- | --- | --- |
| Hash + rich equality (INT/BOOL/FLOAT/STR) | **pycore** | dict, set |
| Linear probe (empty / match / unequal / tombstone) | **pycore** | dict, set |
| Resize / grow | **excore** | list, dict, set |
| Bulk extend / update | **excore** | non-empty `LIST_EXTEND`, `SET_UPDATE` |
| List element shift on delete | **excore** | `DELETE_SUBSCR` list |
| List append grow | **excore** | `LIST_APPEND` at capacity |

Collisions stay on pycore — average probe chains are short. Only capacity-changing
or O(n) memmove work is offloaded; pycore waits for `COMPLETED` (scoreboard later).

## Set layout (element-only open addressing)

```text
obj+0  : { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }

table + i*32 + 0  : element value
table + i*32 + 16 : element tag   // UNINIT=empty; TOMBSTONE=DICT=9
```

Handle: `PY_TAG_SET` + object address. Tombstone remains `PY_TAG_DICT` (sets/dicts unhashable).

## Bytecodes

| Op | Path |
| --- | --- |
| `BUILD_SET` | pycore alloc + insert (same-tag + rich numeric eq) |
| `SET_ADD` | pycore probe/insert; load ≥ 2/3 → `SET_GROW` (13) |
| `SET_UPDATE` | always excore `SET_UPDATE` (14) — bulk like LIST_EXTEND |
| `CONTAINS_OP` on SET | pycore probe + rich eq |
| `DELETE_SUBSCR` on SET | `TYPE` (CPython: sets are not subscriptable) |

## Trap codes

| Code | Name |
| --- | --- |
| 9 | `LIST_GROW` |
| 10 | `LIST_EXTEND` (every non-empty source; empty is a pycore no-op) |
| 11 | `DICT_GROW` |
| 12 | `LIST_DELETE` (shift-down; was DICT_COLLISION — collisions now on pycore) |
| 13 | `SET_GROW` |
| 14 | `SET_UPDATE` |
| 15 | `DICT_UPDATE` (`{**a, **b}` merge; 4-bit trap space full) |
