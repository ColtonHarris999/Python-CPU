# For-loop full support handoff

## Completed

- [x] §10 step 1 — implementation plan and planning indexes (present at session start).
- [x] §10 step 2 — host code-object field 7, CPython 3.14 exception-table parser,
  host byte-offset-to-slot conversion, and unit tests.
- [ ] §10 step 3
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
- BLOCKED — `make docker-all-tests` could not start because Docker is not
  running:

  ```text
  ERROR: failed to connect to the docker API at unix:///var/run/docker.sock;
  check if the path is correct and if the daemon is running:
  dial unix /var/run/docker.sock: connect: no such file or directory
  make: *** [docker-build] Error 1
  ```

## Next session

Implement exactly §10 step 3: the container↔CALL re-entrancy spike from §6.1.
Likely files: `pycore/rtl/pycore_core.sv`,
`pycore/rtl/pycore_cont_list.svh`, `pycore/rtl/pycore_call_fsm.svh`,
`pycore/tb/tb_container.sv`, one focused `pycore/programs/` fixture, and
`Makefile`.

## Blockers

- Required Docker CI remains unrun because no Docker daemon is available.
  Reproduce with `make docker-all-tests` after starting Docker.
- No open implementation questions or truncated §10 step 2 work.
