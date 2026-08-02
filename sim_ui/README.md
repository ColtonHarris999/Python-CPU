# PyCore Interactive Simulator & Debugger UI

Local web UI for the **two-core** PyCore system (pycore + excore). Paste or
drag in a Python file, click **Run**, then step through per-opcode snapshots
of the operand stack, call frames, mailbox/excore handoffs, heap handles, and
the RF window.

## Quick start (clone → run)

Requires **Docker** (includes Python 3.14 and Verilator).

```bash
git clone -b ui https://github.com/ColtonHarris999/Python-CPU.git
cd Python-CPU

make docker-build
make docker-sim-ui
```

Open **http://localhost:8000**

Stop the container with Ctrl+C.

That’s the whole setup: two Make targets after clone.

## How to use the simulation

1. **Run the default program** — click **Run**. You should see `PASS` and
   return `INT 12` (two-core image-boot).
2. **Step** — use **Step ◀ ▶**, the timeline scrubber, or keys `←` / `→`
   (also `j` / `k`). Disassembly highlights the current PC.
3. **Load an example** — dropdown demos:
   - Smoke / recursion / call chain / `CALL_KW`
   - `LIST_EXTEND` → excore mailbox
   - `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` bulk traps
   - Contaminated dict update (stays on pycore)
   - Fatal undef-global trap
4. **Frames** — nested calls show named locals from `co_varnames` when available.
5. **Excore** — mailbox lane lists recoverable trap handoffs (codes 9–14, 19, 20…).
6. **Heap** — click a list/dict/set handle (or a heap-root button) to inspect;
   contamination bit is shown on `MUT_COLLEC`. Contaminated bulk may note
   “bulk on pycore — contaminated”.
7. **RF** — advanced register-file window for locals + operand stack.
8. **Keypoints** — checkbox filters the scrubber to calls / containers / traps.
9. **Drag-and-drop** — drop a `.py` file onto the editor.

### Program shape

```python
def managed_entry():
    return 12

managed_entry()
```

- Entry name defaults to `managed_entry` (toolbar editable).
- Call the entry at module level so image-boot executes it.
- Only the PyCore bytecode subset is supported — see
  [`pycore/docs/bytecode_support.md`](../pycore/docs/bytecode_support.md).
- Unsupported syntax / opcodes fail at image build with a readable error.

### Shortcuts

| Key | Action |
| --- | --- |
| `Ctrl/⌘+Enter` or `F5` | Run |
| `←` / `→` or `k` / `j` | Step back / forward |
| `Home` / `End` | First / last snapshot |

## Native launch (optional)

If you already have Python **3.14**, Verilator, Node.js, and Make:

```bash
pip install -r sim_ui/requirements.txt
make sim-ui-web          # build the frontend once
make excore-fw
make sim-ui-serve        # http://0.0.0.0:8000
```

## Architecture

| Layer | Path |
| --- | --- |
| FastAPI server | `sim_ui/server/` |
| React + Vite UI | `sim_ui/web/` |
| Traced two-core TB | `pycore/tb/tb_sim_trace.sv` |
| Session artifacts | `build/sim_ui/<session_id>/` |

Simulation always uses `EXCORE_EN=1` with firmware from `make excore-fw`.
There is **no** single-core UI mode.

API sketch: `GET /api/health`, `POST /api/sessions`, step/heap/disasm GETs,
`WS /api/sessions/{id}/stream` for progress.

## Make targets

| Target | Purpose |
| --- | --- |
| `make docker-sim-ui` | **Primary** — Docker UI on port 8000 |
| `make docker-build` | Build `python-cpu-sim` image |
| `make sim-ui-web` | Build frontend to `sim_ui/web/dist` |
| `make sim-ui-serve` | Native uvicorn serve |
| `make pycore-sim-trace` | CLI traced run (no UI) |
| `make sim-ui-test` | Unit tests (decode / trace / keypoints) |
| `make docker-sim-ui-e2e` | Verilator e2e smoke → INT 12 |

## Tests

```bash
# Fast unit tests (no Verilator)
docker run --rm -v "$PWD:/work" -w /work -e PYTHONPATH=/work \
  python-cpu-sim make sim-ui-test

# Full e2e smoke (builds + runs traced two-core sim)
make docker-sim-ui-e2e
```

## Limits (v1)

- Per-opcode snapshots (not every microarchitectural cycle).
- Heap object expand uses the end-of-run dmem image; per-step **roots/headers**
  are live from the TB.
- Source-line highlighting is not implemented (PC + disassembly is).
- Not a full CPython debugger; not a VCD browser.
