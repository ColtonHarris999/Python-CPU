# memsim — PyCore memory-system measurement harness

Answers "what would a cache buy PyCore, and which cache?" without needing
Verilator. It is a *trace-and-model* study, not an RTL simulation:

1. `layout.py` folds a program exactly like the production image flow
   (`pycore_cli.prepare_module_code` → `image_from_source.build_image_from_code`)
   and reads **real dmem addresses** out of the built heap image — code-object
   field addresses, `co_consts` / `co_names` tuple bases, the globals and
   builtins dict objects and their tables.
2. `tracer.py` runs the *same folded module code* on CPython 3.14 under
   `sys.monitoring` and records every retired instruction, plus `PY_START` /
   `PY_RETURN` markers so a `CALL` that pushed a Python frame (including a
   recursive one) is distinguishable from a builtin dispatch.
3. `model.py` expands each retired opcode into the dmem access sequence the
   as-built RTL issues, at real addresses, with a live shadow of the globals
   dict so runtime `STORE_NAME` inserts change later probe sequences.
4. `cachesim.py` provides an LRU set-associative cache plus a "result cache"
   model keyed on Python-level identities rather than addresses.
5. `experiments.py` runs E1–E8 and prints the tables.

Run it:

```bash
python3.14 pycore/tools/memsim/experiments.py
```

## Scope and honesty

* **Exactly modelled:** `LOAD_CONST`, `LOAD_GLOBAL` / `LOAD_NAME`,
  `STORE_NAME` / `STORE_GLOBAL`, `CALL` frame entry, `RETURN_VALUE` frame exit
  — i.e. all interpreter *metadata* traffic, at real addresses.
* **Bounded, not modelled:** container/heap traffic (list and dict element
  access, attributes, iterators). E1c estimates it from RTL-counted
  per-opcode access counts. Leaving it out of E1/E3 understates total
  traffic, so every cache saving reported there is a lower bound.
* **Cycle model** (derived by reading `pycore_core.sv`, not measured):
  `S_FETCH` = 3 cycles + 2 per skipped `CACHE`/`EXTENDED_ARG` slot;
  scalar pipe = 4 (`S_DECODE`+`S_EXEC`+`S_MEM`+`S_WB`); container pipe = 3;
  one dependent dmem access inside `S_CONTAINER`/`S_CALL`/`S_RETURN` =
  3 cycles (issue, bank turnaround, observe). Absolute CPO should be
  treated as ±1 cycle/opcode; the *ratios* between configurations are what
  the study is for.

`bench/` holds five workloads written inside the PyCore subset (all pass
`pycore_cli.py lint`); the rest of the program list is repo fixtures.
