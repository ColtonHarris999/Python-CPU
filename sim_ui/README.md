# PyCore Interactive Simulator & Debugger UI

Local web UI for the **two-core** PyCore system (pycore + excore). Paste or
drag in a Python file, click **Run**, then step through per-opcode snapshots
of the operand stack, call frames, mailbox/excore handoffs, and heap handles.

## Quick start (clone → run)

Requires **Docker** (recommended — includes Python 3.14 and Verilator).

```bash
git clone -b ui <repo-url> Python-CPU
cd Python-CPU

make docker-build
make docker-sim-ui
```

Open **http://localhost:8000**

Stop the container with Ctrl+C.

### What to try

1. Click **Run** on the default smoke program (`managed_entry` → `12`).
2. Use **Example → Smoke return 42** or **Fibonacci recursion**.
3. Step with ◀ ▶ or the timeline scrubber; watch the stack and frames.
4. Load **LIST_EXTEND → excore mailbox** or **DICT_UPDATE bulk trap** and open
   the **Excore** tab to see recoverable trap handoffs.
5. Click a list/dict handle on the stack, then open **Heap** to inspect it
   (contamination bit is shown on `MUT_COLLEC` values).

## How to write a program

```python
def managed_entry():
    return 12

managed_entry()
```

- Entry name defaults to `managed_entry` (editable in the toolbar).
- Call the entry at module level so image-boot executes it.
- Only the PyCore bytecode subset is supported — see
  [`pycore/docs/bytecode_support.md`](../pycore/docs/bytecode_support.md).
- Unsupported syntax / opcodes fail at image build with an error in the UI.

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

Simulation always uses `EXCORE_EN=1` with assembled firmware from
`make excore-fw`. There is no single-core UI mode.

## Make targets

| Target | Purpose |
| --- | --- |
| `make docker-sim-ui` | **Primary** — Docker UI on port 8000 |
| `make docker-build` | Build `python-cpu-sim` image |
| `make sim-ui-web` | Build frontend to `sim_ui/web/dist` |
| `make sim-ui-serve` | Native uvicorn serve |
| `make pycore-sim-trace` | CLI traced run (no UI) |
| `make sim-ui-test` | Unit tests (decode / trace parse) |

## Tests

```bash
# Host needs Python 3.14 for unittest discovery of server imports that
# pull image tools; inside Docker:
docker run --rm -v "$PWD:/work" -w /work python-cpu-sim make sim-ui-test
```

## Limits (v1)

- Per-opcode snapshots (not every microarchitectural cycle).
- Heap inspector uses the end-of-run dmem image.
- Source-line highlighting is not implemented (PC + disassembly is).
- Not a full CPython debugger; not a VCD browser.
