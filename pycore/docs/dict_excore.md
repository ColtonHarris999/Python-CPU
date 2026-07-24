# Dict + excore design (layout v2)

## Split (pipelined handoff cost)

| Case | Owner | Notes |
| --- | --- | --- |
| `BUILD_MAP` | **pycore** | Allocates stable 32-byte object + relocatable table |
| Hash INT/BOOL/FLOAT (simple) / SHORT_STR / LONG_STR | **pycore** | INT `-1 → -2` (CPython); BOOL 0/1; FLOAT integer-valued / ±0 match int hashes |
| Same-tag probe (empty / exact match / unequal continue) | **pycore** | Cheap bit compares; linear probe |
| Cross-tag rich equality (INT↔BOOL, INT↔FLOAT, …) | **pycore** | Rich equality (`True==1`, `1.0==1`) on the probe path |
| Tombstone skip / same-tag delete | **pycore** | `PY_TAG_TOMBSTONE` (= `PY_TAG_DICT` / 9; dicts cannot be keys) |
| Cross-tag delete / contains | **pycore** | Same rich-eq probe as STORE / SUBSCR |
| Load ≥ 2/3 before new-key insert | **excore** `DICT_GROW` | Realloc table (`used*4` if used≤50k else `used*2`), rehash, complete STORE |
| Complex object hashes | deferred | TYPE trap for unsupported key tags |

**Why keep collisions on pycore?** Average probe chains are short; a same-tag
or rich numeric compare is cheaper than a memory-ownership handoff. Only
capacity-changing work (`DICT_GROW`) is offloaded. See also
`pycore/docs/set_excore.md` for the shared hash-container / excore split.

## Layout v2

```text
obj+0  : { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }     // 0 if slot_count==0

table + i*64 + 0  : key value
table + i*64 + 16 : key tag   (UNINIT=empty, TOMBSTONE=DICT=9 deleted)
table + i*64 + 32 : value value
table + i*64 + 48 : value tag
```

Handle address is stable across grows (like list `ob_item`).

## Trap codes

| Code | Name | Entries | COMPLETED |
| --- | --- | --- | --- |
| 11 | `DICT_GROW` | dict, key, value | pop 3 (finish STORE insert after rehash) |

Code 12 is `LIST_DELETE` (list shift-down), not dict collision — rich equality
lives on pycore.
