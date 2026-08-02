# PyCore Interactive Simulator & Debugger UI — Implementation Prompt

> **Status:** **Ready for handoff** — approved for implementation by a follow-on agent.
> **Audience:** implementing agent (primary); human reviewer (reference).
> **Type:** Product + engineering brief. Prefer this doc over inventing alternate scope.
>
> **Locked decisions:**
> 1. Always simulate the **full two-core system** (pycore + excore). No single-core mode.
> 2. Prefer **Docker** for the UI/orchestration path so hosts without Python 3.14 still work.
> 3. Implementation work lives on branch **`ui_simulation`**; push after each completed phase.
> 4. Base branch is current **`main`** (PR [#61](https://github.com/ColtonHarris999/Python-CPU/pull/61) / `bytecode_support` **already merged**).
> 5. Defaults locked for kickoff: FastAPI + React/Vite; **per-opcode** snapshots in v1; leave legacy `make run-file` alone; Docker via Make wrapper on port **8000**.

---

## 0. Handoff package (start here)

### 0.1 Prerequisites for the human / dispatcher

1. Merge this planning PR into `main` if it is not already there, **or** ensure the implementing agent can read this file from the planning branch.
2. Spawn the implementing agent with the **§14 kickoff prompt** (copy-paste).
3. Expect work on branch `ui_simulation` and a draft PR `ui_simulation` → `main`.

### 0.2 First commands for the implementing agent

```bash
git fetch origin main
git checkout -b ui_simulation origin/main
# Confirm this brief exists:
test -f planning/pycore_sim_debugger_ui_prompt.md
```

If the brief is not yet on `main`, cherry-pick / merge the planning PR commit(s) that add `planning/pycore_sim_debugger_ui_prompt.md` onto `ui_simulation` before coding, then proceed.

### 0.3 Delivery cadence

| Phase | Goal | After done |
| --- | --- | --- |
| **A** | Docker UI + paste/run + stack stepping on two-core smoke | commit + `git push -u origin ui_simulation` + open/update PR |
| **B** | Frames (`co_varnames`), disasm, errors, excore event lane, scrubber | commit + push |
| **C** | Heap inspector + contamination + richer mailbox | commit + push |
| **D** | Polish, docs, tests | commit + push; mark PR ready if §3.3 met |

Do **not** invent a different branch name. Do **not** offer single-core mode.

### 0.4 Definition of “handoff complete” for *this* planning doc

- [x] Product scope locked (two-core, Docker-first, `ui_simulation`)
- [x] `bytecode_support` on `main` reflected as baseline (not pending)
- [x] Remaining optional product choices locked to defaults (§0 header / §15)
- [x] Phased plan, API sketch, trace contract, demos, risks, checklist present
- [x] Copy-paste kickoff prompt ready (§14)

---

## 1. One-sentence goal

Build a local web app where a user can open a **live PyCore system simulation** (pycore + excore), author or drag-in a Python file, click **Run**, and step through execution while seeing **results plus hardware-faithful visualizations** of call frames, the operand stack, register file, heap data structures, and recoverable trap/mailbox handoffs — essentially a debugger for the two-core PyCore system.

---

## 2. Why this exists (context for the implementer)

PyCore is a SystemVerilog multi-cycle CPU whose ISA is a CPython **3.14** bytecode subset. The repository is a **two-core system**: pycore (bytecode hart) + excore (RV32 firmware hart for recoverable container traps). The UI always targets that system.

| Existing piece | Role today |
| --- | --- |
| `pycore/tools/image_from_source.py` | Preferred path: compile Python → imem/dmem/string hex images (1:1 with CPython code units) |
| `pycore/tools/run_image_test.py` | Image build + host `managed_entry()` expected-result helper |
| `make run-file` / `tb_pycore_runfile.sv` | Legacy single-function preprocess + Verilator run; **not** the UI primary path |
| `make pycore-img-*-two-core` / `PYCORE_IMAGE_RUN_TWOCORE` | Image-boot sims on the two-core top (`EXCORE_EN=1`) — **this is the sim model for the UI** |
| `Dockerfile` (`python:3.14-slim` + Verilator) | Existing container used by `make docker-*` — extend for the UI |
| `pycore/tools/cosim_trace.py` | Trace *summarizer* only; no producer UI exists |
| `dbg_wb_*` ports on `pycore_system` | Minimal writeback shadow for final RF dump |

There is **no frontend**, no step-time debugger, and no structured execution-trace protocol. The UI must sit on top of (and extend) this toolchain — not replace the RTL or invent a second Python interpreter.

### 2.1 Baseline already on `main` (former `bytecode_support`)

PR [#61](https://github.com/ColtonHarris999/Python-CPU/pull/61) is **merged**. Treat the following as required baseline on `origin/main` — not future stretch, not optional:

| Baseline on `main` | Why the sim UI cares |
| --- | --- |
| **7-field code objects** (`co_varnames`, `co_kwdefaults`; metadata packs `kwonlyargcount`) | Frame locals labeled from `co_varnames`; decode/heap inspector uses 224B / 7-field layout |
| **`CALL_KW` / `CALL_FUNCTION_EX`** | Disasm + stack shapes for kw / `*args` / `**kwargs` |
| **`MAP_ADD`, `DICT_UPDATE`, `DICT_MERGE`, bulk `SET_UPDATE`** | Supported opcodes + demos; image_from_source accepts them |
| **`MUT_COLLEC` contamination bit** (`value[123]`) | Heap/handle decode must show sticky contamination; routes bulk ops pycore vs excore |
| **Recoverable traps** including `PY_TRAP_DICT_UPDATE` (19), `PY_TRAP_DICT_MERGE` (20), `SET_UPDATE` (14), list/dict/set grow/extend/delete | Mailbox event lane + trap name table |
| **excore firmware bulk helpers** | Longer ownership grants on dict/set bulk paths |
| **Tooling** (`encoding.make_mut(..., contaminated=)`, image builder, two-core img targets) | Reuse helpers; do not reinvent layouts |

**Base-branch rule (simple):**

```bash
git fetch origin main
git checkout -b ui_simulation origin/main
```

Re-read current `pycore/docs/bytecode_support.md`, `tags.md`, and `architecture.md` on that tip. Planning docs `planning/call_kw_support_plan.md` and `planning/dict_set_bulk_contam_plan.md` are historical design notes (**Done**); defer to docs/RTL if they disagree.

### 2.2 Docs to read before coding

- `README.md`
- `pycore/docs/architecture.md` (frames, RF, boot, traps incl. 19/20, two-core transport, 7-field code objects)
- `pycore/docs/preprocessing_breakdown.md` (image-boot vs deprecated preprocess)
- `pycore/docs/bytecode_support.md` (legal opcodes, including CALL_KW / bulk dict-set)
- `pycore/docs/tags.md` (contamination bit), `pycore/docs/object_model.md`
- `pycore/docs/set_excore.md` / dict excore notes for bulk routing
- `excore/docs/` (mailbox MMIO, firmware build, trap handlers)
- `planning/call_kw_support_plan.md`, `planning/dict_set_bulk_contam_plan.md` (background only)
- `planning/builtins_*` only if adding builtins demos later

---

## 3. Product vision

### 3.1 Must-have user experience

1. **Open the simulator** — one documented command starts the UI (Docker-first; see §8.5).
2. **Load Python source**:
   - Drag-and-drop a `.py` file into the editor pane, **or**
   - Type / paste / edit source in the browser editor.
3. **Configure a short run profile** (defaults):
   - Entry function name: `managed_entry`.
   - Max cycles: generous default (document it; allow override).
   - **No core-mode toggle** — always pycore + excore (`EXCORE_EN=1`, firmware loaded).
4. **Click Run** — build image → two-core Verilator sim → structured trace + final result.
5. **See the result clearly**:
   - Pass / fatal trap / timeout / recoverable-trap activity summary.
   - Decoded return value (tag + human-readable value when possible).
   - Cycle count / opcodes retired / CPO if available.
   - Host expected result when entry returns `int`/`bool` (reuse `run_image_test` helpers); show match/mismatch.
6. **Debug / visualize**:
   - Scrub or step through **per retired opcode** snapshots (v1).
   - Highlight current bytecode (source-line highlight is stretch).
   - Visualize operand stack, call frames, heap structures, RF (advanced).
   - Always show trap / mailbox / `mem_owner` (idle excore still visible as parked).

### 3.2 Explicit non-goals (v1)

- Not a full CPython debugger (no pdb).
- Not a GTKWave-style VCD browser.
- Not full Python — only `bytecode_support.md` + image tooling; clear UI errors otherwise.
- Not RTL microarchitecture rewrites — observation/trace hooks only.
- Not `preprocess.py` / `tb_pycore_runfile` as the primary path.
- Not single-core / `EXCORE_EN=0` UI mode.
- Not multi-user cloud hosting.
- Not perfect decode of every corrupt heap edge case (raw hex fallback OK).

### 3.3 Success definition

A reviewer can:

1. Start the UI with one documented Docker-first command.
2. Drop in `pycore/programs/smoke_return.py` (or equivalent), Run, see return `12` / INT on the **two-core** top.
3. Step a recursive/call-chain program and watch frames + stack change.
4. Run list grow/extend **or** uncontaminated dict update/merge and see heap changes **and** an excore mailbox handoff.
5. Inspect a `MUT_COLLEC` handle and see the **contamination bit**; understand contaminated bulk may stay on pycore.
6. Get a readable build error on unsupported syntax/opcodes (no silent hang).

---

## 4. Recommended architecture

Three layers — do not collapse RTL, orchestration, and UI into one script.

```text
┌─────────────────────────────────────────────────────────────┐
│  Browser UI (editor + debugger panes)                       │
│  - Monaco/CodeMirror editor, drag-drop                      │
│  - Timeline / step controls                                 │
│  - Panels: Result, Stack, Frames, Heap, RF, Excore/events   │
└───────────────────────────▲─────────────────────────────────┘
                            │ HTTP + WebSocket (JSON)  :8000
┌───────────────────────────┴─────────────────────────────────┐
│  Orchestration server (Python 3.14, prefer in Docker)       │
│  - image_from_source build                                  │
│  - optional host expected-result                            │
│  - excore-fw + two-core Verilator traced run                │
│  - parse trace → SessionTrace; serve snapshots              │
└───────────────────────────▲─────────────────────────────────┘
                            │ subprocess / files
┌───────────────────────────┴─────────────────────────────────┐
│  Two-core PyCore system sim (Verilator) + trace hooks       │
│  - pycore_excore_system / image-boot two-core top           │
│  - EXCORE_EN=1, FW_HEX always provided                      │
│  - structured per-opcode (optional per-cycle) log           │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 Suggested repo layout

```text
sim_ui/                      # or pycore/sim_ui/
  README.md                  # Docker-first how-to
  server/                    # FastAPI + uvicorn
    app.py
    image_build.py
    sim_runner.py            # two-core Verilator + artifacts
    trace_parse.py
    decode.py
    models.py
  web/                       # Vite + React + TypeScript
  fixtures/                  # tiny demo programs
Makefile                     # sim-ui / docker-sim-ui (port 8000)
Dockerfile                   # extend python:3.14-slim image as needed
```

**Locked stack defaults:**

- Backend: Python 3.14 + FastAPI + uvicorn (in Docker by default).
- Frontend: Vite + React + TypeScript; Monaco or CodeMirror 6.
- Utilitarian debugger UI — dense and clear, not a marketing page.

---

## 5. Execution & trace contract

### 5.1 Principles

1. **Hardware-faithful** (host Python only for optional expected-result compare).
2. **Opcode-primary timeline** for v1 scrubber steps.
3. Self-describing file trace (JSONL preferred; `key=value` OK if parsed cleanly).
4. **Bounded size:** user max_cycles, max snapshots (~50k), optional keypoint mode.
5. **Server-side decode** to UI JSON.
6. **Always include excore visibility** (`mem_owner`, mailbox edges, parked state).

### 5.2 Minimum snapshot fields

```json
{
  "step": 12,
  "cycle": 840,
  "pc": 42,
  "opcode": "LOAD_FAST",
  "oparg": 0,
  "state": "S_WB",
  "tos": 35,
  "locals_base": 0,
  "tos_base": 32,
  "mem_owner": "PYCORE",
  "rf": { "0": {"tag": "INT", "display": "3", "raw": "..."} },
  "stack": [ {"tag": "INT", "display": "1"}, {"tag": "INT", "display": "2"} ],
  "frames": [
    {
      "depth": 0,
      "func": "managed_entry",
      "pc_return": null,
      "locals": {"a": {"tag": "INT", "display": "3"}},
      "code_addr": "0x..."
    }
  ],
  "heap_delta": [ {"addr": "0x500", "kind": "LIST", "summary": "list len=2 cap=2", "contaminated": false} ],
  "trap": null,
  "excore": {
    "active": false,
    "mailbox": null,
    "last_trap_code": null,
    "last_res_code": null
  },
  "stdout_like": []
}
```

Notes:

- Prefer stack + locals + dirty-RF deltas for large runs.
- Label locals via **`co_varnames`** from 7-field code objects.
- `MUT_COLLEC` decode includes `kind` **and** `contaminated`.
- Trap names must include list/dict/set grow/extend/delete/update **and** `DICT_UPDATE` (19) / `DICT_MERGE` (20).
- Contaminated bulk with no mailbox → UI should say “bulk on pycore — contaminated”, not look broken.

### 5.3 RTL / TB work

1. Extend the **two-core image-boot** TB path (`PYCORE_IMAGE_RUN_TWOCORE` / `pycore-img-*-two-core`), not `tb_pycore_runfile`.
2. Always `EXCORE_EN=1` + `FW_HEX` (`excore-fw`).
3. Trace enable + output path (plusarg / parameter / env file).
4. Per opcode (stable WB / PC advance): cycle, pc, opcode, oparg, tos/bases, live RF window, frame depth, `mem_owner`, trap/mailbox edges.
5. End record: return entry + PASS/FAIL/FATAL_TRAP/TIMEOUT (machine-readable).
6. Isolate hierarchical peeks in one helper module.

### 5.4 Source ↔ bytecode mapping

- Code object → imem range; disassembly list for PC highlight.
- Source-line mapping via `co_linetable` is stretch; PC/disasm is enough for v1.

---

## 6. UI specification

### 6.1 Layout

```text
┌──────────────────────────────┬────────────────────────────────┐
│ Toolbar: Run | Step◀ ▶ | ▷▷  │ Status: PASS/TRAP · cycles ·   │
│ Entry · max cycles           │ return value · mem owner       │
├──────────────────────────────┼────────────────────────────────┤
│ Source editor                │ Visualizations (tabbed/split)  │
│ (drag-drop target)           │  • Operand stack               │
│                              │  • Call frames                 │
│ Disassembly (optional)       │  • Heap / object inspector     │
│                              │  • Excore / mailbox events     │
│                              │  • RF raw (advanced)           │
├──────────────────────────────┴────────────────────────────────┤
│ Timeline scrubber                                             │
└───────────────────────────────────────────────────────────────┘
```

### 6.2 Interactions

| Action | Behavior |
| --- | --- |
| Drag `.py` | Load text; mark session stale |
| Edit text | Mark stale; no auto-run |
| Run | Build+sim progress; then enable stepping |
| Step / scrub | Move snapshot index; refresh panes |
| Click handle | Open object inspector |
| Unsupported opcode | Error panel; no sim |

### 6.3 Visualization rules

- **Tagged values:** tag name, short display, raw hex on hover.
- **Stack:** consistent TOS orientation; highlight push/pop deltas.
- **Frames:** depth, label, return PC; locals from `co_varnames`; show argcount/kwonly when useful.
- **Heap:** LIST/DICT/SET/TUPLE/STR/CODE(7-field)/OBJECT; always show MUT_COLLEC kind + contamination.
- **Excore:** `mem_owner` chip; mailbox events with taxonomy names; contaminated bulk annotation when no handoff.
- **Fatal traps:** banner + freeze scrubber.

### 6.4 Demo programs (examples menu)

Reuse fixtures on `main` where possible:

- `smoke_return.py` — trivial return
- call / recursion — frames
- `img_call_kw` / `img_call_function_ex*` — kw / vararg stack shapes
- list/dict build + index — heap
- list grow / extend — classic mailbox
- `img_dict_update` / `img_dict_merge` / `img_set_update*` — **required** bulk-trap demos
- optional contaminated-key demo — pycore-owned bulk / TYPE gap clarity
- fatal trap demo — trap UX

---

## 7. Backend API sketch

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Python 3.14, verilator, docker/runtime, two-core/fw ready |
| `POST` | `/api/sessions` | `{source, entry, max_cycles}` → build+run two-core traced sim |
| `GET` | `/api/sessions/{id}` | Status, result, error |
| `GET` | `/api/sessions/{id}/steps/{n}` | Snapshot n |
| `GET` | `/api/sessions/{id}/steps?from=&to=` | Bulk range |
| `GET` | `/api/sessions/{id}/heap/{addr}?step=` | Expanded object decode |
| `GET` | `/api/sessions/{id}/disasm` | PC → mnemonic |
| `WS` | `/api/sessions/{id}/events` | Optional progress stream |

No `mode=single|two-core` field.

Session dirs under `build/sim_ui/<session_id>/`; TTL/LRU cleanup.

**Security:** no arbitrary path reads; cap source size / max_cycles; kill runaway sims; only use existing host helpers for expected-result compare.

---

## 8. Integration with Make / Python / Docker

### 8.1 Image build

```text
source text → image_from_source → program.hex, dmem.hex, string_mem.hex, image.meta
```

Entry convention: `managed_entry()` (+ module-level call as in `img_*` fixtures). Document in UI help.

### 8.2 Simulation (always two-core)

Match `PYCORE_IMAGE_RUN_TWOCORE` flags: `EXCORE_EN=1`, `FW_HEX`, shared dmem/mailbox/ownership.

Add a dedicated traced runner, e.g.:

```bash
make pycore-sim-trace \
  RUN_SOURCE=... \
  TRACE_JSONL=build/sim_ui/.../trace.jsonl \
  MAX_CYCLES=...
# depends on excore-fw; always EXCORE_EN=1
```

### 8.3 Decoding

Extend `pycore/tools/encoding.py` / heap helpers. Reuse `make_mut(..., contaminated=)`, `mut_contaminated`, 7-field code-object readers.

### 8.4 Python version

Require **Python 3.14** inside the orchestration environment (Docker provides it).

### 8.5 Docker-first launch (primary)

Extend existing `Dockerfile` (`FROM python:3.14-slim` + Verilator):

1. Documented path:
   ```bash
   make docker-build
   make docker-sim-ui          # publish host port 8000
   ```
2. Install server deps in image; serve built frontend static assets (or documented dev compose).
3. Mount/copy repo so Verilator can compile RTL and write `build/sim_ui/...`.
4. `/api/health` reports Python 3.14 + fw availability.
5. Native launch may exist for developers with local 3.14 + Verilator, but is **secondary** in docs.

---

## 9. Git / branch workflow

**Branch name is fixed:** `ui_simulation`

1. Create from up-to-date `main` (already includes `bytecode_support`):
   ```bash
   git fetch origin main
   git checkout -b ui_simulation origin/main
   ```
2. All implementation commits on `ui_simulation`.
3. After each phase: commit + `git push -u origin ui_simulation`.
4. One PR: `ui_simulation` → `main` (draft OK until Phase A/B solid).
5. If `main` moves, merge `origin/main` into `ui_simulation` before continuing.
6. Do not rename the branch.

---

## 10. Phased delivery

### Phase A — Vertical slice

- `make docker-sim-ui` (or equivalent) works on port 8000.
- Paste/drag source → image build → **traced two-core** sim.
- Trace: step, cycle, pc, opcode, stack, mem_owner, return summary.
- Minimal UI: editor, Run, result, stack, step buttons.
- Smoke: `managed_entry` → INT `12`.

**Exit:** smoke demo works; UI shows two-core active. **Then push `ui_simulation`.**

### Phase B — Frames + disasm + errors + excore lane

- Frames with `co_varnames` locals.
- Disasm synced to PC (CALL_KW / bulk opcodes when present).
- Polished build/trap/timeout errors; timeline scrubber.
- Mailbox event lane with post-merge trap names; ≥1 bulk or list-grow demo.

**Exit:** nested named locals + mailbox handoff + fatal trap name. **Then push.**

### Phase C — Heap inspector (+ contamination)

- On-demand LIST/DICT/SET/TUPLE/STR/CODE/OBJECT decode.
- Contamination bit visible; bulk routing explained.
- Richer mailbox payloads as available.

**Exit:** inspectable heap; uncontaminated update/merge shows excore; contam visible. **Then push.**

### Phase D — Polish

- Examples menu, shortcuts, in-memory sessions, keypoint mode.
- `sim_ui/README.md` + root README link (Docker-first).
- Unit tests (decode, trace parse) + golden JSONL (prefer bulk mailbox) + Docker e2e smoke if feasible.

**Then push; mark PR ready if §3.3 met.**

---

## 11. Testing requirements

1. Unit tests for decode + trace parser (no Verilator).
2. Golden JSONL fixture with ≥1 mailbox handoff (`DICT_UPDATE` / `DICT_MERGE` / `LIST_GROW`).
3. Docker e2e if possible: POST smoke session → INT 12.
4. Do not weaken existing `make pycore-test` / image differentials; new hooks off-by-default for old TBs.
5. If RTL/TB changes: run `pycore-img-smoke-two-core` at minimum; plus a grow/extend or dict-update two-core test when mailbox tracing touches shared modules.

---

## 12. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Hierarchical peeks brittle | One TB/trace helper; prefer RF/PC/tos/frame/`mem_owner`/mailbox |
| Huge traces | Caps, deltas, keypoint mode |
| Weak line mapping | PC/disasm first |
| Legacy preprocess divergence | Do not use `preprocess.py` as primary |
| FW/build coupling | `excore-fw` in Make/Docker path; health fails if missing |
| Host Python conflicts | Docker-first `python:3.14-slim` |
| Host `exec` for expected result | Existing helper only; no client path reads |
| Wrong branch name | Only `ui_simulation` |
| Stale trap tables | Use current `pycore_defs` / architecture taxonomy (incl. 19/20) |
| Missing mailbox on contaminated bulk | Show contamination + “pycore-owned bulk” |

---

## 13. Deliverables checklist

- [ ] Branch **`ui_simulation`** from current `main`, phase commits pushed
- [ ] `sim_ui/` (or equivalent) server + web client
- [ ] Docker-first one-command launch on port **8000**
- [ ] Image-boot **two-core** traced path (`EXCORE_EN=1` always)
- [ ] Decode: **7-field code objects**, **contamination bit**, traps **19/20**
- [ ] UI: drag/drop + edit, Run, result, step/scrub
- [ ] Panels: stack, frames (named locals), excore/mailbox, heap+contam, RF advanced
- [ ] Clear errors for unsupported Python / fatal traps / timeouts
- [ ] Tests: decode + trace parse (+ golden mailbox); smoke documented
- [ ] `sim_ui/README.md` (+ root README link): Docker launch + bytecode subset limits
- [ ] No deprecated-preprocess primary path; no single-core UI mode
- [ ] PR `ui_simulation` → `main` updated each phase

---

## 14. Prompt for the implementing agent (copy-paste kickoff)

```text
Implement the PyCore Interactive Simulator & Debugger UI described in
`planning/pycore_sim_debugger_ui_prompt.md` (read §0 handoff + full doc).

Git workflow (mandatory):
- git fetch origin main
- git checkout -b ui_simulation origin/main
  (main already includes bytecode_support / PR #61)
- If the planning brief is not on main yet, bring
  planning/pycore_sim_debugger_ui_prompt.md onto this branch first.
- Commit and push to origin/ui_simulation after each completed phase.
- Open/update one PR: ui_simulation → main.

Read README.md and the pycore/excore docs cited in the brief (tags
contamination bit, 7-field code objects, trap codes including 19/20).
Execute Phase A first and push; continue through Phase B and push.
Do not start Phase C/D unless A/B are solid or the user asks.

Constraints:
- Always two-core (pycore + excore, EXCORE_EN=1). No single-core mode.
- Docker-first launch (extend Dockerfile / make docker-*); publish port 8000.
- image_from_source + two-core image-boot tops only as primary path
  (not preprocess.py / tb_pycore_runfile).
- Assume current main ISA: CALL_KW/CALL_FUNCTION_EX, MAP_ADD,
  DICT_UPDATE/DICT_MERGE/SET_UPDATE bulk routing, MUT_COLLEC contamination bit.
- Trace hooks only; do not change architectural execution semantics.
- Keep existing make test targets green.
- New code under sim_ui/ (or pycore/sim_ui/) + minimal Makefile/README/Docker wiring.
- Match §3.1 must-haves and §3.3 success definition.
- Stack defaults: FastAPI + React/Vite; per-opcode snapshots in v1.

Acceptance for the first push/PR slice (Phase A):
- Docker-first one-command UI launch on :8000
- Paste/drag Python with managed_entry, Run on two-core sim, see decoded return
- Step through snapshots with operand stack visualization
- Document Docker launch and supported Python subset
```

---

## 15. Locked defaults & closed reviewer questions

| Topic | Decision |
| --- | --- |
| Core mode | Always two-core |
| Launch | Docker-first; port **8000**; Make wrapper (`docker-sim-ui`) preferred over bespoke compose unless compose is clearly simpler |
| Implementation branch | **`ui_simulation`** |
| Base | Current **`main`** (bytecode_support merged via #61) |
| UI stack | FastAPI + React/Vite + Monaco/CodeMirror |
| Trace fidelity v1 | Per-opcode snapshots (finer phase/cycle optional later) |
| Legacy `make run-file` | Leave as-is (out of scope) |
| Planning status | Ready for handoff — implementing agent may start |

No further human decisions are required to begin Phase A.
