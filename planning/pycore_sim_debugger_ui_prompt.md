# PyCore Interactive Simulator & Debugger UI — Implementation Prompt

> **Status:** Draft for human review (refined). Not yet approved for implementation.
> **Audience:** (1) reviewer approving scope, (2) implementing agent executing after approval.
> **Type:** Product + engineering brief. Prefer this doc over inventing alternate scope.
>
> **Locked decisions (from reviewer):**
> 1. Always simulate the **full two-core system** (pycore + excore). No single-core mode.
> 2. Prefer **Docker** for the UI/orchestration path so hosts without Python 3.14 still work.
> 3. Implementation work lives on branch **`ui_simulation`**; push after each completed phase.

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
| `make run-file` / `tb_pycore_runfile.sv` | Legacy single-function preprocess + Verilator run; prints final `RETURN_*` + RF dump |
| `make pycore-img-*-two-core` / `PYCORE_IMAGE_RUN_TWOCORE` | Image-boot sims on the two-core top (`EXCORE_EN=1`) — **this is the sim model for the UI** |
| `Dockerfile` (`python:3.14-slim` + Verilator) | Existing container used by `make docker-*` — extend for the UI |
| `pycore/tools/cosim_trace.py` | Trace *summarizer* only; no producer UI exists |
| `dbg_wb_*` ports on `pycore_system` | Minimal writeback shadow for final RF dump |

There is **no frontend**, no step-time debugger, and no structured execution-trace protocol. The UI must sit on top of (and extend) this toolchain — not replace the RTL or invent a second Python interpreter.

Canonical docs to read before coding:

- `README.md`
- `pycore/docs/architecture.md` (frames, RF, boot, traps, two-core transport)
- `pycore/docs/preprocessing_breakdown.md` (image-boot vs deprecated preprocess)
- `pycore/docs/bytecode_support.md` (what user programs may legally contain)
- `pycore/docs/tags.md`, `pycore/docs/object_model.md`
- `excore/docs/` (mailbox MMIO, firmware build, trap handlers)
- `planning/builtins_*` only as background if builtins demos are added later

---

## 3. Product vision (approval checklist)

### 3.1 Must-have user experience

1. **Open the simulator** — one documented command starts the UI (prefer Docker; see §8.5).
2. **Load Python source** in either way:
   - Drag-and-drop a `.py` file from the user's machine into the editor pane.
   - Type / paste / edit source in a code editor in the browser.
3. **Configure a short run profile** (sensible defaults):
   - Entry function name (default: `managed_entry`).
   - Max cycles.
   - **No core-mode toggle** — every run is the full pycore + excore system (`EXCORE_EN=1`, firmware loaded).
4. **Click Run** — backend builds a PyCore image from the source, launches the **two-core** Verilator simulation, and streams or returns a structured execution trace + final result.
5. **See the result clearly**:
   - Pass / fatal trap / timeout / recoverable-trap activity summary.
   - Decoded return value (tag + human-readable value when possible).
   - Cycle count / opcodes retired / CPO if available.
   - Host expected result when the entry returns `int`/`bool` (reuse `run_image_test` host path); show match/mismatch.
6. **Debug / visualize the run** (debugger-like):
   - Scrub or step through execution snapshots (at least per retired opcode; finer cycle detail is a plus).
   - Highlight the current bytecode / source line when mapping is available.
   - Visualize **operand stack** (RF\[32..95\] live window relative to TOS).
   - Visualize **call frames** (frame-stack descriptors in dmem `0x1C000`–`0x1FFFF`, plus locals window RF\[0..31\]).
   - Visualize **heap data structures** reachable from handles (lists/dicts/sets/tuples/strings/code objects/objects) with tag-aware decoding.
   - Always show **trap / mailbox / memory-ownership** events (pycore ↔ excore), including idle periods where excore is parked.

### 3.2 Explicit non-goals (v1)

- Not a full CPython debugger (no pdb, no CPython frame objects as source of truth).
- Not an FPGA bitstream / waveform viewer (GTKWave-style VCD browsing is optional later).
- Not supporting the full Python language — only what `bytecode_support.md` + image tooling accept. Unsupported constructs must fail at image-build with a clear UI error.
- Not rewriting RTL microarchitecture. Add **observation / trace hooks** only as needed.
- Not using deprecated `preprocess.py` for the primary path. Prefer **image-boot** (`image_from_source.py`).
- Not offering a single-core / `EXCORE_EN=0` simulation mode in the UI.
- Not multi-user cloud hosting in v1 — local single-user tool is enough.
- Not pretty-printing every possible heap corruption edge case; best-effort decode with raw hex fallback is fine.

### 3.3 Success definition (human-approvable)

A reviewer can:

1. Start the UI with one documented command (Docker-first).
2. Drop in `pycore/programs/smoke_return.py` (or type an equivalent `managed_entry`), click Run, and see return `12` / INT on the **two-core** top.
3. Step a recursive or call-chain program (e.g. `img_recursion` / `call_chain`) and watch call frames and stack grow/shrink.
4. Run a small list grow / extend program and see both heap changes **and** an excore mailbox handoff in the event lane.
5. On unsupported syntax/opcodes, get a readable build error in the UI, not a silent hang.

---

## 4. Recommended architecture

Keep three layers. Do not collapse RTL, orchestration, and UI into one script.

```text
┌─────────────────────────────────────────────────────────────┐
│  Browser UI (editor + debugger panes)                       │
│  - Monaco/CodeMirror editor, drag-drop                      │
│  - Timeline / step controls                                 │
│  - Panels: Result, Stack, Frames, Heap, RF, Excore/events   │
└───────────────────────────▲─────────────────────────────────┘
                            │ HTTP + WebSocket (JSON)
┌───────────────────────────┴─────────────────────────────────┐
│  Orchestration server (Python 3.14, prefer in Docker)       │
│  - Validate / build image via image_from_source             │
│  - Optional host expected-result via run_image_test helpers │
│  - Build/load excore firmware; invoke two-core Verilator    │
│  - Parse sim stdout/trace → SessionTrace model              │
│  - Serve session + step snapshots to UI                     │
└───────────────────────────▲─────────────────────────────────┘
                            │ subprocess / files
┌───────────────────────────┴─────────────────────────────────┐
│  Two-core PyCore system sim (Verilator) + trace hooks       │
│  - pycore_excore_system (or equivalent image-boot two-core) │
│  - EXCORE_EN=1, FW_HEX always provided                      │
│  - Emits structured per-opcode (and optional per-cycle) log │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 Suggested repo layout (implementer may adjust names, not responsibilities)

```text
sim_ui/                      # or pycore/sim_ui/
  README.md                  # how to run the UI (Docker-first)
  server/                    # FastAPI (or similar) orchestration
    app.py
    image_build.py           # thin wrapper over image_from_source
    sim_runner.py            # two-core Verilator invoke + artifact dirs
    trace_parse.py           # lines → SessionTrace
    decode.py                # tag/entry → JSON-friendly values
    models.py                # pydantic / dataclasses
  web/                       # frontend (Vite + React/TS preferred)
    ...
  fixtures/                  # tiny demo programs for UI smoke
Makefile additions           # `make sim-ui` / `make docker-sim-ui` (preferred)
Dockerfile / compose tweak   # reuse python:3.14-slim image; expose UI port
planning/… (this doc)        # stays as the product brief
```

**Stack guidance (defaults if no strong repo preference):**

- Backend: Python 3.14 + FastAPI + uvicorn, run inside the repo Docker image by default.
- Frontend: Vite + React + TypeScript (can be built in Docker or served as static assets from the container).
- Editor: Monaco or CodeMirror 6.
- No new heavyweight design system; keep the UI utilitarian and debugger-clear (dense but readable). This is a developer tool, not a marketing landing page — prioritize information density and step clarity over brand hero layouts.

---

## 5. Execution & trace contract (the hard part)

Today’s `tb_pycore_runfile` only reports the final return and a coarse RF shadow, and it is a **single-core** path. The UI debugger needs a **time series on the two-core system top**.

### 5.1 Trace design principles

1. **Hardware-faithful:** values come from sim/RTL observation, not from re-interpreting Python on the host (except optional expected-result compare).
2. **Opcode-primary timeline:** v1 scrubber steps are “opcode retired” (or “entered S_WB / equivalent”). Optional sub-steps for multi-cycle container ops and excore service intervals can be phase markers.
3. **Self-describing lines** the existing `cosim_trace.py` style can grow into, e.g. space-separated `key=value` plus a JSON snapshot mode for the UI.
4. **Bounded size:** large programs must not explode RAM. Caps:
   - max cycles (user-set),
   - max retained snapshots (e.g. 50k),
   - optional “keypoints only” mode (CALL/RETURN/trap/mailbox/container mutate).
5. **Decode on the server** into UI-friendly JSON so the browser does not reimplement tag layouts.
6. **Always include excore visibility:** even when no recoverable trap fires, the UI/trace should make clear that the two-core system is active (e.g. mem owner = PYCORE, excore parked). When a recoverable trap fires, record mailbox req/res and ownership flips.

### 5.2 Minimum snapshot fields (per step)

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
  "rf": { "0": {"tag": "INT", "display": "3", "raw": "..."}, "...": "..." },
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
  "heap_delta": [ {"addr": "0x500", "kind": "LIST", "summary": "list len=2 cap=2"} ],
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

- Full RF every step is OK for small runs; for larger runs prefer stack + locals + dirty-RF deltas.
- `heap_delta` can be “handles touched this step”; a separate endpoint can expand a handle into a full decoded object graph on demand.
- Function names: best-effort from image metadata / `co_names` / source map; fall back to code-object address.
- When excore owns memory / services a trap, either emit dedicated steps or annotate the straddling pycore steps with mailbox transition events so the scrubber can pause on handoffs.

### 5.3 RTL / TB work required

Implement observation without changing architectural behavior:

1. Extend the **two-core image-boot testbench path** used by `PYCORE_IMAGE_RUN_TWOCORE` / `pycore-img-*-two-core` (not legacy `tb_pycore_runfile` + `preprocess.py`).
2. Always build/run with `EXCORE_EN=1` and a firmware hex (`excore-fw` / `FW_HEX`), matching Makefile two-core targets.
3. Add a **trace enable** plus output path (plusarg, parameter, or env-selected file).
4. At a stable point each opcode (e.g. end of writeback / when PC advances), dump:
   - cycle, pc, opcode, oparg
   - tos / locals_base / tos_base
   - RF entries that are in the live locals+stack window (or full 96)
   - frame-stack top pointer / depth if available
   - `mem_owner`, trap_code if asserted
   - mailbox req/res summary (trap_code, res_code, pop/push counts, heap_ptr) on handoff edges
5. On program end: emit final return entry, PASS/FAIL/FATAL_TRAP/TIMEOUT reason (machine-readable).
6. Keep `$display` human logs, but make the **file trace** the API the server parses.

If hierarchical TB peeks (`dut.core.*`, mailbox, grant mux) are already the house style, continue that pattern for v1 rather than a large DPI redesign — but isolate peek logic in one TB/helper so it can be replaced later.

### 5.4 Source ↔ bytecode mapping

Provide enough mapping for the editor to highlight:

- Module/function code object → imem entry slot range.
- Optional: disassembly list (`pc → opcode mnemonic`) from the built image (host can disassemble with `dis` / existing analyze tools).
- Best-effort Python line mapping via CPython `co_linetable` if present in compile artifacts; if painful, v1 may highlight **disassembly PC** only and treat source-line highlight as stretch.

---

## 6. UI specification

### 6.1 Layout (single composition, debugger-first)

```text
┌──────────────────────────────┬────────────────────────────────┐
│ Toolbar: Run | Step◀ ▶ | ▷▷  │ Status: PASS/TRAP · cycles ·   │
│ Entry · max cycles           │ return value · mem owner       │
├──────────────────────────────┼────────────────────────────────┤
│ Source editor                │ Visualizations (tabbed/split)  │
│ (drag-drop target overlay)   │  • Operand stack               │
│                              │  • Call frames                 │
│ Disassembly (optional pane)  │  • Heap / object inspector     │
│                              │  • Excore / mailbox events     │
│                              │  • RF raw (advanced)           │
├──────────────────────────────┴────────────────────────────────┤
│ Timeline scrubber  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
└───────────────────────────────────────────────────────────────┘
```

### 6.2 Interactions

| Action | Behavior |
| --- | --- |
| Drag `.py` onto editor | Load text; mark session stale until re-run |
| Edit text | Mark stale; do not auto-run |
| Run | Disable controls; show build+sim progress; on completion load step 0 or last; enable stepping |
| Step forward/back | Move snapshot index; refresh all panes from that snapshot |
| Click timeline | Jump to step |
| Click stack/frame/heap handle | Open object inspector for that address |
| Unsupported opcode at build | Show error panel with tool message; no sim |

### 6.3 Visualization rules (domain-specific)

**Tagged values** always show: tag name, short display, raw hex on hover.

**Operand stack:** vertical TOS-on-top or TOS-at-bottom (pick one, stay consistent); empty slots not shown; highlight pushes/pops between steps.

**Call frames:** stack of frames with function label, depth, return PC; selected frame shows locals by name when names are known (`co_varnames` if available from image/metadata — add metadata export if missing).

**Heap structures:**

- LIST: length, capacity, element array (decoded entries)
- DICT/SET: len, slot table summary, insertion-order keys when applicable
- TUPLE: size + elements
- SHORT_STR / LONG_STR: decoded text (truncate long)
- CODE_OBJECT: entry_slot, nlocals, stacksize, argcount
- OBJECT: kind + fields per `object_model.md`
- MUT_COLLEC kind nibble must be decoded (LIST/DICT/SET/…)

**Excore / mailbox:** persistent status chip for current `mem_owner`; event list for trap_req / trap_res with codes from the architecture taxonomy (`LIST_GROW`, `LIST_EXTEND`, `DICT_GROW`, …). Recoverable service intervals should be obvious while scrubbing.

**Fatal traps:** banner with code name; freeze scrubber at trap step.

### 6.4 Demo programs

Ship UI-loadable demos (buttons or examples menu), reusing existing programs where possible:

- `smoke_return.py` — trivial return (two-core still active)
- call / recursion example — frames
- list/dict build + index — heap
- list grow / extend (or other recoverable trap) — **required** excore mailbox demo
- a program that fatal-traps (type or mem fault) — trap UX

---

## 7. Backend API sketch

Implement roughly these endpoints (names flexible; keep the responsibilities):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Python version, verilator present, docker/runtime info, repo root, confirms two-core/fw ready |
| `POST` | `/api/sessions` | Body: source text, entry, max_cycles → create session, build+run two-core traced sim (or async job) |
| `GET` | `/api/sessions/{id}` | Status, result summary, error |
| `GET` | `/api/sessions/{id}/steps/{n}` | Snapshot n |
| `GET` | `/api/sessions/{id}/steps?from=&to=` | Bulk range for scrubbing |
| `GET` | `/api/sessions/{id}/heap/{addr}` | Expanded object decode at step (query `step=`) |
| `GET` | `/api/sessions/{id}/disasm` | PC → mnemonic listing |
| `WS` | `/api/sessions/{id}/events` | Optional: build/sim progress streaming |

There is **no `mode=single|two-core` field** — sessions always use the two-core system.

Use a per-session temp dir under `build/sim_ui/<session_id>/` for hex, meta, fw reference, trace, logs. Clean up old sessions (TTL or LRU).

**Security (local tool, still be sane):**

- Do not `eval` user source on the server except through the existing image/host helpers.
- Cap source size and max_cycles.
- Run Verilator with timeouts; kill runaway sims.
- No arbitrary path reads from the client beyond the session sandbox.

---

## 8. Integration with existing Make / Python / Docker tools

### 8.1 Image build

Primary:

```text
Python source (text)
  → image_from_source.build_image_from_source_text / write_image_outputs
  → program.hex, dmem.hex, string_mem.hex, image.meta
```

Validate unsupported opcodes the same way tooling already does; surface stderr/exceptions to the UI.

Entry convention: match repo programs — define `managed_entry()` (or user-selected name) and typically call it at module level for image-boot, consistent with `img_*` fixtures. Document this in the UI help strip.

### 8.2 Simulation (always two-core)

Wrap the same Verilator top/flags the Makefile uses for `PYCORE_IMAGE_RUN_TWOCORE` / `pycore-img-*-two-core`:

- `EXCORE_EN=1`
- `FW_HEX` from `make excore-fw` (or equivalent)
- Shared dmem / mailbox / ownership mux as in `pycore_excore_system`

Prefer a **new Make target or Python runner** dedicated to traced two-core runs rather than scraping unrelated test PASS lines.

Example shape:

```bash
make pycore-sim-trace \
  RUN_SOURCE=... \
  TRACE_JSONL=build/sim_ui/.../trace.jsonl \
  MAX_CYCLES=...
# always depends on excore-fw; always EXCORE_EN=1
```

…or a Python equivalent used by both Make and the server.

Do **not** wire the UI to `tb_pycore_runfile` / single-core `pycore_system` as the primary path.

### 8.3 Decoding

Centralize tag/entry decoding in one Python module (extend `pycore/tools/encoding.py` / heap helpers rather than duplicating constants). Mirror layouts in:

- `pycore/docs/tags.md`
- `heap_image.py` / architecture memory map
- frame descriptor layout in `architecture.md`
- mailbox / trap codes in `architecture.md` + `excore/docs/mmio_map.md`

### 8.4 Python version

Image tools require **Python 3.14**. Do not ask users to install 3.14 on the host if Docker can provide it.

### 8.5 Docker-first launch (required preference)

Use / extend the existing `Dockerfile` (`FROM python:3.14-slim` + Verilator) so the orchestration server and image-build tools run with a known interpreter.

Expectations:

1. **Primary documented path** is Docker, e.g.:
   - `make docker-build`
   - `make docker-sim-ui` (or `docker compose up`) publishing the UI port (e.g. `8000`) to the host browser.
2. The container must include whatever the server needs beyond the base image (e.g. `pip install` for FastAPI/uvicorn; Node only if the frontend is built inside the container — baking a production static build into the image is fine).
3. Mount or copy the repo so Verilator can compile RTL and write `build/sim_ui/...` artifacts.
4. `/api/health` should report that it is running under the expected Python 3.14 and that excore firmware build is available.
5. A native (non-Docker) launch may exist for developers who already have Python 3.14 + Verilator, but it is secondary in docs and must not be the only path.
6. Goal: avoid “works on my machine” Python-version conflicts for reviewers and later agents.

---

## 9. Git / branch workflow for the implementing agent

**Branch name is fixed:** `ui_simulation`

Rules:

1. Create the branch from up-to-date `main` when implementation starts:
   ```bash
   git fetch origin main
   git checkout -b ui_simulation origin/main
   ```
2. Do **all** implementation commits on `ui_simulation` (not on ad-hoc agent branches, unless temporarily experimenting — land results on `ui_simulation`).
3. After finishing **each phase** (A/B/C/D), commit with a clear message and push:
   ```bash
   git push -u origin ui_simulation
   ```
4. Open or update **one PR** from `ui_simulation` → `main` (draft OK). Update the PR description as phases land.
5. If `main` moves, merge/rebase `origin/main` into `ui_simulation` and resolve conflicts before continuing a phase.
6. Do not rename the branch. The reviewer will look specifically for `ui_simulation`.

---

## 10. Phased delivery plan

Implement in phases so a partial PR on `ui_simulation` is still reviewable. **Push after each phase.**

### Phase A — Vertical slice (approve-to-demo)

- Docker-first launch path works (`make docker-sim-ui` or equivalent).
- Server can build image from pasted source and run a **traced two-core** sim for a trivial program.
- Trace contains at least: step, cycle, pc, opcode, stack list, mem_owner, return summary.
- Minimal web UI: editor, Run, result panel, stack panel, step buttons.
- Works for `managed_entry` returning a small INT.

**Exit criteria:** drag/paste `smoke_return.py` → Run → see `12`, step through a few opcodes with stack updates; health/UI indicates two-core system.  
**Then:** commit + `git push -u origin ui_simulation`.

### Phase B — Frames + disassembly + errors + excore event lane

- Call frame panel with depth and locals.
- Disassembly pane synced to PC.
- Image-build / fatal-trap / timeout errors polished in UI.
- Timeline scrubber.
- Excore/mailbox event lane present (even if only idle + one demo handoff).

**Exit criteria:** recursion/call-chain demo shows nested frames; grow/extend demo shows mailbox handoff; fatal trap demo shows code name.  
**Then:** commit + push `ui_simulation`.

### Phase C — Heap inspector

- On-demand heap decode for LIST/DICT/SET/TUPLE/STR/CODE/OBJECT.
- Highlight mutated handles across steps.
- Richer mailbox payload display (trap entries / result entries) as available.

**Exit criteria:** list/dict demo inspectable; grow path shows heap resize + excore completion.  
**Then:** commit + push `ui_simulation`.

### Phase D — Polish

- Examples menu, keyboard shortcuts (Run, Step), session persistence in memory only.
- Trace size controls / keypoint mode.
- Docs: `sim_ui/README.md` + link from root `README.md` (Docker-first instructions).
- Basic automated tests: decode unit tests, trace parser tests, one end-to-end “build+parse smoke” if CI/Docker can run Verilator.

**Then:** commit + push `ui_simulation`; mark PR ready if acceptance (§3.3) is met.

---

## 11. Testing requirements for the implementing agent

1. **Unit tests** for tag/entry decode and trace parser (no Verilator).
2. **Golden trace fixture** (checked-in small JSONL, including at least one mailbox handoff) to lock UI/server parsing.
3. **Manual/scripted e2e:** via Docker if possible — POST session with smoke program, assert return INT 12 on two-core path.
4. Do **not** weaken existing `make pycore-test` / image differentials; new hooks must be off-by-default or unused by existing TBs.
5. If RTL/TB changes land, run relevant two-core image tests (`pycore-img-smoke-two-core` at minimum; plus a grow/extend two-core test if mailbox tracing touches shared modules).

---

## 12. Implementation constraints & risks

| Risk | Mitigation |
| --- | --- |
| Hierarchical signal peeks brittle across RTL refactors | Isolate in one TB/trace module; prefer stable architectural state (RF, PC, tos, frame ptr, mem_owner, mailbox) |
| Trace files huge | Caps, deltas, keypoint mode |
| Line mapping incomplete | Ship PC/disasm highlight first |
| `run-file` preprocess path diverges from image-boot | Do not build the UI on `preprocess.py` |
| Two-core always-on adds FW/build coupling | Depend on `excore-fw` in the sim-ui Make/Docker path; fail health check if FW missing |
| Host Python version conflicts | Docker-first launch using `python:3.14-slim` image; native path secondary |
| Security of `exec` in host expected-result | Reuse existing helper; only for compare; never trust client paths |
| Agents invent alternate branch names | Hard requirement: land work on `ui_simulation` only |

---

## 13. Deliverables checklist (agent definition of done)

- [ ] Implementation branch **`ui_simulation`** pushed to origin with phase commits
- [ ] `sim_ui/` (or equivalent) with server + web client
- [ ] Docker-first Make/docs entry point: one command to launch the UI
- [ ] Image-boot **two-core** run path with structured trace output (`EXCORE_EN=1` always)
- [ ] UI: load source (drag/drop + edit), Run, result, step/scrub
- [ ] Panels: stack, frames, excore/mailbox events, heap inspector (per phase), basic RF/advanced raw
- [ ] Clear errors for unsupported Python / fatal traps / timeouts
- [ ] Tests for decode + trace parse; smoke path documented
- [ ] Root or `sim_ui` README section describing UX, Docker launch, and limits (bytecode subset, Python 3.14 in container)
- [ ] No reliance on deprecated preprocess as the primary path
- [ ] No single-core UI mode
- [ ] This planning doc updated with “Implemented” notes / deviations only if approval changes scope

---

## 14. Prompt for the implementing agent (copy-paste kickoff)

After a human approves this document, an implementing agent should treat the following as the task statement:

```text
Implement the PyCore Interactive Simulator & Debugger UI described in
`planning/pycore_sim_debugger_ui_prompt.md`.

Git workflow (mandatory):
- Create/use branch exactly named `ui_simulation` from up-to-date main.
- Commit and push to `origin/ui_simulation` after each completed phase.
- Open/update one PR from `ui_simulation` → `main`.

Read that planning document fully, then read README.md and the pycore/excore
docs it cites. Execute Phase A first and push; continue through Phase B and
push. Do not start Phase C/D unless Phase A/B are solid or the user asks to
go further.

Constraints:
- Always simulate the full two-core system (pycore + excore, EXCORE_EN=1).
  Do not offer or default to single-core.
- Prefer Docker for launch/orchestration (extend existing Dockerfile /
  make docker-* flow) so Python 3.14/Verilator are container-provided.
- Prefer image_from_source / two-core image-boot tops; do not make
  preprocess.py or tb_pycore_runfile primary.
- Add RTL/TB observation hooks only as needed for tracing; do not change
  architectural execution semantics.
- Keep existing make test targets green.
- Put new code under a dedicated sim_ui (or pycore/sim_ui) tree plus minimal
  Makefile/README/Docker wiring.
- Match the UX must-haves in §3.1 and the success definition in §3.3.

Acceptance for the first push/PR slice:
- Docker-first one-command UI launch
- Paste/drag Python with managed_entry, Run on two-core sim, see decoded return
- Step through snapshots with operand stack visualization
- Document Docker launch and supported Python subset
```

---

## 15. Reviewer notes (for you)

Already locked from feedback:

- ✅ Always two-core (pycore + excore)
- ✅ Docker-first to avoid host Python conflicts
- ✅ Implementation branch name: `ui_simulation`

Still optional to amend before kickoff:

1. **UI stack:** FastAPI + React/Vite default OK, or prefer a simpler single-page + Starlette/Flask approach?
2. **Trace fidelity:** Per-opcode snapshots OK, or need true per-cycle / per-container-phase stepping in v1?
3. **Legacy `make run-file`:** Leave as-is (recommended), or also migrate it to image-boot as drive-by work? (Drive-by not required.)
4. **Published port / compose:** Any preference for port number or docker compose vs plain `docker run` Make wrapper?

Mark remaining decisions at the top of this file when approved, then hand the §14 kickoff prompt to an implementing agent.
