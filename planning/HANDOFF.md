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
- [x] §10 step 6 — Track A GET_ITER OBJECT + HEAP_ITER + FOR_ITER + §6.1.1
  protocol raise boundary.
- [x] §10 step 7 — Track C list comp end-to-end (two-core).
- [x] §10 step 8 — docs + RTL `CODE_NFIELDS`/`CODE_OBJECT_BYTES` 8/256 sync.

## Design locks

- Code objects have eight 32-byte fields (256 bytes total); field index 7 is a
  `TUPLE` of tagged `INT` values preserving each raw `co_exceptiontable` byte
  (§5.2–§5.3). RTL `PYCORE_CODE_NFIELDS` / `PYCORE_CODE_OBJECT_BYTES` match
  host `encoding.CODE_OBJECT_NFIELDS` / `CODE_OBJECT_BYTES` (8 / 256).
- `pycore/tools/exception_table.py` mirrors CPython 3.14's 6-bit varint parser
  without importing private `dis` APIs (§4.3).
- Host slot conversion keeps `start_slot`/`end_slot` relative to the code
  object's entry and emits an absolute `target_slot = code_entry_slot +
  (target >> 1)` (§5.6). RTL must not redo byte-offset arithmetic.
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
- `CONTAINER_CALL_SPIKE_EN` is default-off and test-only.
- Heap ends at `PYCORE_HEAP_LIMIT = 0x1B000`. Exc-info arena occupies
  `0x1B000–0x1BFFF` (`pycore_exc_stack`); frame stack remains `0x1C000–0x1FFFF`.
- Boot builtins seed a leaf `StopIteration` `OBK_TYPE`. The same handle is
  written to `ITER_EXHAUST_TYPE_ADDR` (`0x1BFE0`) and latched into
  `iter_exhaust_type_r` during `S_BOOT` (no builtins-dict probe).
- `RAISE_VARARGS` 1 / `CONT_RAISE`: allocate `OBK_EXCEPTION` (empty args tuple
  `{size=0,addr=0}`), walk code field 7 varints as relative slots, redirect on
  hit (do **not** set `active_exc_r` until `PUSH_EXC_INFO`), else set
  `active_exc_*` and `PY_TRAP_RAISE` — unless protocol-launched (§6.1.1).
- Handler opcodes: `PUSH_EXC_INFO` / `CHECK_EXC_MATCH` / `POP_EXCEPT` /
  `RERAISE` as in steps 4–5.
- Track A: OBJECT `GET_ITER`/`HEAP_ITER`/`FOR_ITER` via ATTR borrow + protocol
  CALL; §6.1.1 `call_exc_*` + `iter_exhaust_type_r` for StopIteration exhaust.
- Host `# pycore-expect: <int>` for goldens CPython cannot execute.
- Track C: real `compile()` list comps on two-core (`pycore-img-list-comp-*`);
  aggregate `pycore-img-for-loop-all`. Comprehension docs are **Option B**.
- Optional follow-ons (not required for plan close): dict comps from
  `compile()`, ROM `iter`/`next` protocol rewrite.

## Verified

- PASS — `make PYTHON=python3.14 pycore-python-tests` (216 tests).
- PASS — `make PYTHON=python3.14 pycore-img-list-comp-basic` (golden 10).
- PASS — `make PYTHON=python3.14 pycore-img-list-comp-fast-clear` (golden 106).
- PASS — `make PYTHON=python3.14 pycore-img-for-iter-object-list` (step 6).
- PASS — `make PYTHON=python3.14 pycore-img-try-stopiteration` (step 5).
- BLOCKED — `make docker-all-tests` (no Docker daemon).

## Next session

Plan §10 steps 1–8 are complete on this branch. Remaining work is optional
follow-on (dict comps, ROM `iter`/`next`) and unblocking
`make docker-all-tests` once a Docker daemon is available. Prefer merge prep /
CI green over new scope.

## Blockers

- Required Docker CI remains unrun because no Docker daemon is available.
