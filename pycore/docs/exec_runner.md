# `exec` / `shell`: compile and run a file on PyCore

`pycore_cli.py exec FILE` and the interactive `pycore_cli.py shell` give
PyCore a Python file as **source text**. The hart compiles it with the
resident on-device `compile()` (`compiler.md`), runs it with `exec()`, and
streams what it prints. The same file then runs on stock CPython 3.14 as a
golden, and the report compares output and cost.

```bash
make shell                                   # power on, then type file paths
make exec-file RUN_SOURCE=path/to/prog.py    # one shot
make exec-file RUN_SOURCE=prog.py EXEC_ARGS="--mem-latency 30 --cache-en 0"
python3.14 pycore/tools/pycore_cli.py exec a.py b.py --json out.json
```

Compare with `run`, where host CPython compiles the module into the boot
image and the hart only executes `managed_entry()`.

## How it works

| Piece | File |
| --- | --- |
| CLI entry points (`exec`, `shell`) | `pycore/tools/pycore_cli.py` |
| Harness, simulator driver, report | `pycore/tools/pycore_exec.py` |
| Interactive session | `pycore/tools/pycore_shell.py` |
| CPython reference run | `pycore/tools/host_reference.py` |
| Phase marks, perf counters, heartbeat | `pycore/tb/tb_container.sv` (`+PHASE_MARKS=1`, `+HEARTBEAT=N`) |

1. The file is read as-is. If it defines `managed_entry()` and never calls
   it, a call is appended (as `run` does).
2. A boot **harness** module is built with the source embedded as a string
   constant. It is an ordinary host-compiled image, so the resident compiler
   is in code RAM at reset:

   ```python
   _bi_print("\x01"); _bi_print("\x02")        # entry mark + calibration mark
   code = compile(SRC, FILENAME, "exec")        # on-device compiler
   _bi_print("\x03")
   exec(code, {"__name__": "__main__"})         # fresh namespace
   _bi_print("\x04")
   ```

   The compile and exec calls are wrapped in one `except` clause per seeded
   exception type, so a Python-level exception is reported by name and
   message. Heap and code-RAM watermarks (`_bi_heap_mark` /
   `_bi_code_mark`) are read around each phase.
3. The shared two-core `tb_container` runs with `+PHASE_MARKS=1`. Console
   bytes `0x01..0x07` are not written to stdout. Each one prints a
   `PHASE_MARK` line with the cycle count, instructions issued, excore
   handoffs and wait cycles, and L1I/L1D hits and misses. `+HEARTBEAT=N`
   prints progress every N cycles for the live counter.
4. The harness's metadata travels on the console between `SO`/`SI`
   (`0x0e`/`0x0f`) and is stripped from the program output.
5. `host_reference.py` runs in a separate CPython 3.14 interpreter.

Every run starts from a reset. One program cannot leave state behind for
the next, and the `boot` line in the report is the reset-to-harness cost.

## Report

```text
==== PyCore report: pycore/programs/demo_exec.py =============================
  Result   PASS -- output matches CPython
  ...
               PyCore cycles    @100 MHz    CPython cycles  CPython time  PyCore/CPython
  compile          6,271,880    62.72 ms          ~903,455      430.2 us            6.9x
  run                 68,594    685.9 us           ~29,072       13.8 us            2.4x
  total            6,340,474    63.40 ms          ~932,528      444.1 us            6.8x
  PyCore detail
    boot (reset -> harness entry)     3,307 cycles (+1,344 per phase mark, subtracted)
    compile  241,136 bytecodes issued, 26.0 cycles/bytecode; excore 1 handoffs / 1,624 cycles
             L1I hit 68.3%, L1D hit 94.6%
    run      1,133 bytecodes issued, 60.5 cycles/bytecode; excore 26 handoffs / 41,802 cycles
    compiled output                  182 code-RAM slots (CPython: 165 instructions, 321 code units with CACHE)
    heap used                        compile 389,504 B (64% of free heap), run 5,568 B
    ...
```

**Result** is one of the following:

| Result | Meaning |
| --- | --- |
| `PASS` | Same stdout as CPython. Also given when both raised the same exception, or both compilers rejected the file. |
| `MISMATCH` | stdout differs (a diff is shown), or only one side raised. |
| `UNSUPPORTED` | The on-device `compile()` raised `SyntaxError` on code CPython accepts, because it is outside the T1–T5 grammar. |
| `TRAP` | A hardware trap halted the hart. The report gives the trap name, the phase, and a likely cause. |
| `TIMEOUT` | `--max-cycles` was reached. |
| `RAN` | The CPython comparison is off (`--no-host`, `set compare off`). |

The exit status is 0 for `PASS` / `RAN` and 1 otherwise.

**Metrics:**

| Metric | Definition |
| --- | --- |
| PyCore cycles | Cycles between phase marks, minus one mark's cost (the calibration pair measures one `_bi_print`). A `+` means a trap cut the phase short. |
| @N MHz | PyCore cycles at an assumed clock (`--pycore-mhz`, default 100), for a wall-clock comparison. |
| CPython cycles | Hardware CPU cycles from `perf_event_open` when the kernel exposes them. Otherwise `~` marks an estimate: wall time × nominal clock (`/proc/cpuinfo`, or `PYCORE_HOST_GHZ`). VMs and containers usually have no PMU. |
| CPython time | The first (cold) call, which is what PyCore is compared against. The warm best of repeated calls is printed underneath. |
| bytecodes issued | Instructions latched by fetch, `EXTENDED_ARG` included. Run-phase counts include ROM builtins such as `print()` and `sum()`, which are bytecode on PyCore and C on CPython. That is why PyCore issues more than CPython's `sys.monitoring` count. |
| excore handoffs / cycles | Recoverable traps handed to the RV32 companion (container growth, `print`), and the cycles pycore spent marshalling and waiting for them. |
| compiled output | Code-RAM slots `compile()` allocated, next to CPython's instruction and code-unit counts for the same file. |
| heap used | Bytes allocated by `compile()` and by the program run. `compile()` keeps its whole working set (see `compiler.md` Lifetime). |
| free at boot | Code-RAM slots and heap bytes left for the program after the compiler image loads. |

`report.json` in the build directory (default `build/pycore_exec/`) holds
every number, the raw marks, and the full CPython measurement. `sim.log` is
the raw testbench output.

## Shell commands

| Command | Effect |
| --- | --- |
| `FILE.py` or `run FILE.py ...` | Compile and run on PyCore, then compare |
| `again` / `r` | Re-run the last file, picking up edits and new settings |
| `set cache on\|off` | `+CACHE_EN` |
| `set latency N` | `+MEM_LATENCY` |
| `set max-cycles N` | Cycle budget per run (default 200M) |
| `set mhz N` | Assumed clock for the wall-clock column |
| `set compare on\|off` | CPython reference run |
| `set progress on\|off` | Live cycle counter |
| `show`, `ls [DIR]`, `help`, `quit` | |

Tab completes file paths. History is kept in `build/.pycore_shell_history`.

## Limits you will hit

The simulator runs at about 85–90k cycles per second. On-device compile
costs roughly 150–250k cycles per source line, so a 40-line file needs
about a minute before its first output.

| Symptom | Cause |
| --- | --- |
| `TRAP TYPE` during run | `print()` of a `str` longer than 15 bytes, a `float`, or a container. The native print sink takes INT/BOOL/None/SHORT_STR only (`pycore_firmware/builtins/print.md`). |
| `TRAP MEM_FAULT` during compile | The compiler ran out of heap. It keeps roughly 5–10 KB per source line, and about 600 KB is free at boot, so files of more than about 60–100 lines do not fit yet. |
| `UNSUPPORTED` | `class`, `import`, `with`, annotations, generator expressions, slice steps, and the other `compiler.md` exclusions. |
| `TRAP DIV_ZERO`, `MEM_FAULT` during run | Division by zero, a missing dict key, a bad or negative index, or an unbound name. These are hardware traps, not catchable exceptions yet. |
