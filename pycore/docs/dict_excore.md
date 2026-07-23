# Dict + excore design (layout v2)

## Split (pipelined handoff cost)

| Case | Owner | Notes |
| --- | --- | --- |
| `BUILD_MAP` | **pycore** | Allocates stable 32-byte object + relocatable table |
| Hash INT/BOOL/FLOAT (simple) / SHORT_STR / LONG_STR | **pycore** | INT `-1 → -2` (CPython); BOOL 0/1; FLOAT integer-valued / ±0 match int hashes |
| Same-tag probe (empty / exact match / unequal continue) | **pycore** | Cheap bit compares; linear probe |
| Cross-tag probe hit (INT↔BOOL, INT↔FLOAT, …) | **excore** `DICT_COLLISION` | Rich equality (`True==1`, `1.0==1`); finish the opcode |
| Tombstone skip / same-tag delete | **pycore** | `PY_TAG_TOMBSTONE` (= unused `SET` tag) |
| Cross-tag delete / contains | **excore** `DICT_COLLISION` | Same trap; opcode selects semantics |
| Load ≥ 2/3 before new-key insert | **excore** `DICT_GROW` | Realloc table (`used*4` if used≤50k else `used*2`), rehash, complete STORE |
| Complex object hashes | deferred | TYPE trap for unsupported key tags |

**Why not send every linear-probe collision to excore?** Same-tag INT/INT clusters (`0` vs `4` on a 4-slot table) are common and only need a 64-bit compare. Handing those to excore would dominate the pipeline restart cost. Cross-tag / resize / rich equality are the expensive cases.

## Layout v2

```text
obj+0  : { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }     // 0 if slot_count==0

table + i*64 + 0  : key value
table + i*64 + 16 : key tag   (UNINIT=empty, TOMBSTONE=deleted)
table + i*64 + 32 : value value
table + i*64 + 48 : value tag
```

Handle address is stable across grows (like list `ob_item`).

## Trap codes

| Code | Name | Entries | COMPLETED |
| --- | --- | --- | --- |
| 11 | `DICT_GROW` | dict, key, value | pop 3 (finish STORE insert after rehash) |
| 12 | `DICT_COLLISION` | dict, key [, value] | opcode-dependent (see firmware) |

Opcode is in `MB_INSTR_*` so one COLLISION handler serves STORE / SUBSCR / DELETE / CONTAINS.
