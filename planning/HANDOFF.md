# For-loop full support handoff

## Completed

- [x] §10 step 1 — implementation plan and planning indexes (present at session start).
- [x] §10 step 2 — host code-object field 7, CPython 3.14 exception-table parser,
  host byte-offset-to-slot conversion, and unit tests.
- [x] §10 step 3 — container↔CALL pause/resume contract plus a synthetic
  nested-call simulation spike.
- [x] §10 step 4 — Track B dmem exc-info stack, boot/`iter_exhaust_type_r`,
  `get_exception_handler`, and §7.5 `RAISE_VARARGS` path.
- [x] §10 step 5 — active exception + `PUSH_EXC_INFO` / `CHECK_EXC_MATCH` /
  `POP_EXCEPT` / `RERAISE` + §7.7 handler bytecode closure (StopIteration tests).
- [ ] §10 step 6
- [ ] §10 step 7
- [ ] §10 step 8

## Design locks

- Code objects have eight 32-byte fields (256 bytes total); field index 7 is a
  `TUPLE` of tagged `INT` values preserving each raw `co_exceptiontable` byte
  (§5.2–§5.3).
- `pycore/tools/exception_table.py` mirrors CPython 3.14's 6-bit varint parser
  without importing private `dis` APIs (§4.3).
- Host slot conversion keeps `start_slot`/`end_slot` relative to the code
  object's entry and emits an absolute `target_slot = code_entry_slot +
  (target >> 1)` (§5.6). RTL must not redo byte-offset arithmetic.
- Do not update the RTL code-object constants in `pycore_defs.svh` before §10
  step 8; those constants are currently documentation-only and have no RTL
  consumers. Field index 7 is readable via `pycore_code_field_val_addr` /
  `PYCORE_CODE_FIELD_CO_EXCEPTIONTABLE` without bumping `CODE_NFIELDS`.
- A container arm launches a protocol call only after arranging an ordinary
  positional-CALL RF layout, moving to its wait phase, and setting
  `container_call_pending_r`. The shared handoff snapshots the container
  op/phase, bytecode PC/oparg/opcode, TOS, and both decoded operands before
  entering the existing `S_CALL` FSM.
- Protocol calls always present `cur_arg_r = 0` to `S_CALL`; the original
  container oparg is restored on return. This is required because `FOR_ITER`'s
  oparg is a jump delta, not a CALL argument count. A staged non-NULL self is
  still counted by the existing method-call path.
- `container_call_active_r` plus the saved target frame depth distinguishes the
  outer protocol return from ordinary nested returns. Nested calls resume
  fetch; only the outer return restores the saved container context and
  re-enters `S_CONTAINER`.
- `S_RETURN` preserves its normal RF writeback and caller-PC redirect while
  also latching a stable `container_call_result_r`. CALL is allowed to reuse
  container scratch registers; resumptions must use the saved operand/result,
  not assume arbitrary scratch survived.
- `CONTAINER_CALL_SPIKE_EN` is default-off and test-only. Its synthetic
  `CONT_GET_ITER` arm consumes an already CALL-ready `[callable, NULL]` stack;
  real OBJECT resolution, bound-self staging, and HEAP_ITER behavior remain
  §10 step 6.
- Heap ends at `PYCORE_HEAP_LIMIT = 0x1B000`. Exc-info arena occupies
  `0x1B000–0x1BFFF` (`pycore_exc_stack`); frame stack remains `0x1C000–0x1FFFF`.
- Boot builtins seed a leaf `StopIteration` `OBK_TYPE`. The same handle is
  written to `ITER_EXHAUST_TYPE_ADDR` (`0x1BFE0`) and latched into
  `iter_exhaust_type_r` during `S_BOOT` (no builtins-dict probe).
- `RAISE_VARARGS` 1 / `CONT_RAISE`: allocate `OBK_EXCEPTION` (empty args tuple
  `{size=0,addr=0}`), walk code field 7 varints as relative slots, redirect on
  hit (do **not** set `active_exc_r` until `PUSH_EXC_INFO`), else set
  `active_exc_*` and `PY_TRAP_RAISE`.
- `PUSH_EXC_INFO`: dmem-push prior `active_exc_*`; stack `[exc]→[prev|None,exc]`;
  set `active_exc_r` from TOS. `CHECK_EXC_MATCH`: v1 exact handle compare of
  TOS type vs `active_exc.field0`; `[exc,type]→[exc,bool]`. `POP_EXCEPT`:
  dmem-pop restore + pop TOS. `RERAISE` 0/1: re-enter table walk on TOS exc;
  oparg=1 does **not** dmem-pop (cleanup bytecode already ran `POP_EXCEPT`).

## Verified

- PASS — `make PYTHON=python3.14 pycore-python-tests` (216 tests).
- PASS — `make PYTHON=python3.14 pycore-img-raise-varargs` (trap 17).
- PASS — `make PYTHON=python3.14 pycore-img-raise-stopiteration-fatal` (trap 17).
- PASS — `make PYTHON=python3.14 pycore-img-try-stopiteration` (golden 7; 513 cycles).
- PASS — `make PYTHON=python3.14 pycore-img-try-stopiteration-nested`
  (golden 11; 894 cycles; dmem exc-info + cleanup `RERAISE` 1).
- BLOCKED — `make docker-all-tests` (no Docker daemon).

## Next session

Implement exactly §10 step 6: Track A GET_ITER object + HEAP_ITER + FOR_ITER
+ §6.1.1 container protocol raise boundary (`exc_type_matches` +
`iter_exhaust_type_r`). Do not start list-comp Track C (step 7) or docs-only
step 8.

## Blockers

- Required Docker CI remains unrun because no Docker daemon is available.
- No open implementation questions or truncated §10 step 5 work.
