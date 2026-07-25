# PyCore dead-code audit report

Branch: `cursor/pycore-deadcode-09ee`  
Scope: entire `pycore/` tree (RTL, TB, tools, programs, docs, Makefile hooks).  
Constraints applied:

- **Kept** `pycore/rtl/attic/pycore_frame_buffer.sv` (future RF-window / spill study).
- **Kept** all excore integration paths (recoverable traps, marshal/wait FSM, grow/extend/delete/set traps, `pycore_excore_system`), even where single-core tests take the fatal path.

---

## 1. Removed — RTL / SVH

| Instance | Location | Why dead |
|---|---|---|
| `container_dict_collision_trap_r` + `dict_collision_sig` | `pycore_core.sv` | Dict/set rich-eq collisions run on pycore; stub never fired meaningfully |
| `dict_collision_i` input + priority arm | `pycore_trap.sv` | Only consumer of the stub above |
| `CP_EXT_SRC_BUF` / `CP_EXT_DST_VAL` / `CP_EXT_DST_TAG` | `pycore_core.sv` | LIST_EXTEND copy phases retired when non-empty extend moved to excore |
| `container_dst_len_r` | `pycore_core.sv` | Written on STORE_SUBSCR index path; never read after extend offload |
| `cont_ext_hdr_cap`, `cont_ext_dst_idx` | `pycore_core.sv` | Only used by removed extend-copy phases |
| `cont_dict_hash_rs1`, `cont_dict_hash_rs2` | `pycore_core.sv` | Computed, never sampled (probe uses `cont_dict_hash`) |
| Decode locals `dec_push` / `dec_pop` / `dec_pc` | `pycore_core.sv` | Core owns TOS; ports now tied off at instantiation |
| `pycore_dict_key_rich_maybe` | `pycore_defs.svh` | Superseded by `pycore_dict_key_rich_eq` |
| `pycore_dict_obj_bytes`, `pycore_dict_table_bytes` | `pycore_defs.svh` | No callers; sizing goes through `pycore_dict_alloc_bytes` |
| `pycore_set_obj_bytes`, `pycore_set_table_bytes` | `pycore_defs.svh` | Same for sets |
| `pycore_set_slot_count_from_hdr`, `pycore_set_used_from_hdr` | `pycore_defs.svh` | Unused wrappers over header fields |
| `pycore_tuple_addr` | `pycore_defs.svh` | Unused; callers use `value[63:0]` / tag helpers |
| `pycore_code_field_tag_addr` | `pycore_defs.svh` | Thin alias of `pycore_tuple_tag_addr`; unused |
| `pycore_code_meta_stacksize` | `pycore_defs.svh` | Never read by boot/call path |
| `PY_OP_SET_FUNCTION_ATTRIBUTE` | `pycore_defs.svh` | Opcode not implemented / not decoded |
| `branch_trap_code` wire | `pycore_core.sv` | Driven by `pycore_branch`; unread — branch traps fold into `PY_TRAP_TYPE` |
| `PYCORE_SHORT_STR_FLAG_MSB/LSB` | `pycore_defs.svh` | Declared only; payload/size bitfields are the live ones |
| `pycore_const_table.sv` | `rtl/attic/` | Superseded by image-boot `LOAD_CONST`; not in `PYCORE_RTL_SRCS` |

---

## 2. Removed — testbenches / Makefile stubs

| Instance | Why dead |
|---|---|
| `tb/tb_pycore.sv` | Pre-3.14 inline 3-slot `LOAD_CONST` e2e TB; `make pycore-top` was already a no-op echo |
| `tb/tb_multifn.sv` | Pre-3.14 CALL/`LOAD_CONST` multifn TB; `make pycore-multifn` was a no-op echo |
| `make pycore-top` / `pycore-multifn` targets + `pycore-test` deps | Stub targets with no simulation |
| Duplicate `pycore-img-string-ops:` recipe | Identical Makefile rule listed twice |

---

## 3. Removed — tools / Python

| Instance | Why dead |
|---|---|
| `encoding.bool_value` | Defined/imported, never called |
| `encoding.format_entry` | Only imported by preprocess; never called |
| `heap_image._key_equal` | Legacy wrapper; never called (`dict_key_rich_eq` is the live path) |
| Unused `preprocess.py` imports | `ENTRY_HEX_DIGITS`, short-str shift constants, `STRING_RUNTIME_BASE`, `TAG_NULL`, `TAG_UNINIT`, `VAL_*`, `float_bits`, `field` |
| Unused `gen_excore_integration_fixtures.py` imports | `TAG_CODE_OBJECT`, `pack_code_metadata` |
| Unused `test_preprocess_containers.py` import | `types` |

---

## 4. Removed — orphaned programs / sidecars

| Cluster | Why dead |
|---|---|
| `mem_demo_{prog,consts}.hex` | Only consumer was deleted `tb_pycore` |
| `multifn_{simple,const,chain,stress}.{py,hex}`, `multifn_arg.hex` | Only consumer was deleted `tb_multifn` |
| `container_across_call{,_str}.hex` | Makefile target already removed |
| `image_boot{,_dmem,_str}.hex`, `image_boot_meta.txt` | Superseded by generated `build/img_*` image-boot flow |
| `dict_bool_key.*`, `dict_str_key.*`, `dict_str_key_long.*`, `list_float_key.*` | Retired pre-3.14 container fixtures; no Makefile/TB refs |
| All checked-in `programs/*_cache.hex` and `programs/*.types` | Preprocess sidecars never loaded by `tb_container` / image-boot |

---

## 5. Docs / comments cleaned

| Change | Reason |
|---|---|
| `rtl/attic/README.md` | Now documents only the retained frame buffer |
| `tb_container.sv` header | Dropped reference to deleted `tb_multifn` |
| `docs/architecture.md` tuple helpers list | Removed deleted `pycore_tuple_addr` |
| Root `README.md` | Dropped `pycore-top`, `RUN_CONST_HEX`, and dead “Legacy core / tb_pycpu” section |

---

## 6. Intentionally retained (not dead for this project)

| Item | Reason |
|---|---|
| `rtl/attic/pycore_frame_buffer.sv` | Explicit future deep-call / spill design study |
| `EXCORE_EN`, `S_TRAP_MARSHAL` / `S_TRAP_WAIT`, mailbox ports, `pycore_trap_recoverable` | Live two-core path |
| Grow / extend / list-delete / set-grow / set-update trap codes + marshal regs | Excore feature surface |
| `CONT_LIST_EXTEND` empty/self/`CP_SRC_HDR` path | Live empty no-op + trap decision on pycore |
| `PY_TAG_FRAME_OBJECT` / encoding mirror | Reserved tag in the 4-bit space |
| `pycore_system.sv` | Still used by `tb_pycore_runfile` and `EXCORE_EN=0` |
| Active container `.hex`/`.py` used by `make pycore-container` | Live regression fixtures |
| Entire `excore/` unused firmware stubs / future handlers | Out of scope; user asked to keep excore unused material |

---

## 7. Ambiguous (reported, not deleted)

| Item | Why left alone |
|---|---|
| `pycore_decode` ports `decoded_valid_o` / `push_stack_o` / `pop_stack_o` / `decoded_pc_o` | Still emitted; core ties them off. Narrowing the module is an API change (see optimization plan) |
| `pycore_trap` `trap_pc_o` / `trap_rs1_o` / `trap_rs2_o` | Tied off today; plausible cosim/debug hooks |
| `pycore_regfile` idle `push_stack_i` / `pop_stack_i` | API cleanup, not a pure delete |
| `PYCORE_CODE_NFIELDS` / `PYCORE_CODE_OBJECT_BYTES` | Layout documentation constants; Python side is live |
| `preprocess.py` module itself | Deprecated but still backs `make run-file` / type-pair flows |
| Demo sources `bubble_sort.py`, `fib_iterative.py`, `float_dot_product.py`, `mixed_arith.py` | Not in CI; kept as manual examples |
| `cosim_trace.py` | Docs-only today; may return with cosim work |

---

## 8. Verification notes

After cleanup, representative targets expected to stay green:

- `make pycore-python-tests`
- `make pycore-img-smoke`
- `make pycore-container` (subset or full)
- `make excore-cpu-test` / `pycore-excore-system` (excore paths untouched)
