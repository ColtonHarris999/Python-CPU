# For-loop full support handoff

## Completed

- [x] §10 step 1 — implementation plan and planning indexes (present at session start).
- [x] §10 step 2 — host code-object field 7, CPython 3.14 exception-table parser,
  host byte-offset-to-slot conversion, and unit tests.
- [x] §10 step 3 — container↔CALL pause/resume contract plus a synthetic
  nested-call simulation spike.
- [ ] §10 step 4
- [ ] §10 step 5
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
  consumers.
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

## Verified

- PASS — required Python 3.14 §0 preflight:
  - `python3.14 -c "import dis; dis.dis('for x in [1]: pass')"`
  - `python3.14 -c "import dis; dis.dis(compile('def f(): return [x for x in range(3)]','<x>','exec'))"`
  - `python3.14 -c "from dis import _parse_exception_table; ..."`
  - `python3.14 -c "import dis; ...; dis.dis(co)"`
- PASS — `PYTHONPATH=pycore/tools python3.14 -m unittest pycore.tests.test_exception_table pycore.tests.test_image_from_source`
  (53 tests).
- PASS — `make PYTHON=python3.14 pycore-python-tests` (215 tests).
- PASS — `make PYTHON=python3.14 pycore-img-for-iter-all` (all native
  `img_for_iter_*` regressions).
- PASS — `make PYTHON=python3.14 pycore-img-container-call-spike`
  (`__iter__` launches from `S_CONTAINER`, makes a nested ordinary CALL,
  returns a three-element LIST, resumes the paused arm, then returns `len == 3`;
  751 cycles).
- BLOCKED — `make docker-all-tests` could not start because Docker is not
  running:

  ```text
  ERROR: failed to connect to the docker API at unix:///var/run/docker.sock;
  check if the path is correct and if the daemon is running:
  dial unix /var/run/docker.sock: connect: no such file or directory
  make: *** [docker-build] Error 1
  ```

## Next session

Implement exactly §10 step 4: Track B dmem exception stack,
boot/`iter_exhaust_type_r` (§7.4), `get_exception_handler`, and the §7.5 raise
path. Do not start active-exception opcodes from step 5 or object iteration from
step 6.

## Blockers

- Required Docker CI remains unrun because no Docker daemon is available.
  Reproduce with `make docker-all-tests` after starting Docker.
- Production bound-method/self staging is intentionally deferred to §10 step 6;
  the default-off synthetic trigger tests only the shared step 3 handoff.
- No open implementation questions or truncated §10 step 3 work.
