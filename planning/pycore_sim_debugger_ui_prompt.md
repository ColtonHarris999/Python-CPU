# PyCore Interactive Simulator & Debugger UI — Implementation Prompt

> **Status:** Draft for human review. Not yet approved for implementation.
> **Audience:** (1) reviewer approving scope, (2) implementing agent executing after approval.
> **Type:** Product + engineering brief. Prefer this doc over inventing alternate scope.

---

## 1. One-sentence goal

Build a local web app where a user can open a **live PyCore simulation**, author or drag-in a Python file, click **Run**, and step through execution while seeing **results plus hardware-faithful visualizations** of call frames, the operand stack, register file, and heap data structures — essentially a debugger for the PyCore CPU.

---

## 2. Why this exists (context for the implementer)

PyCore is a SystemVerilog multi-cycle CPU whose ISA is a CPython **3.14** bytecode subset. The repo already has:

| Existing piece | Role today |
| --- | --- |
| `pycore/tools/image_from_source.py` | Preferred path: compile Python → imem/dmem/string hex images (1:1 with CPython code units) |
| `pycore/tools/run_image_test.py` | Image build + host `managed_entry()` expected-result helper |
| `make run-file` / `tb_pycore_runfile.sv` | Legacy single-function preprocess + Verilator run; prints final `RETURN_*` + RF dump |
| `make pycore-img-*` / two-core tops | Differential image-boot sims (prefer this model for new work) |
| `pycore/tools/cosim_trace.py` | Trace *summarizer* only; no producer UI exists |
| `dbg_wb_*` ports on `pycore_system` | Minimal writeback shadow for final RF dump |

There is **no frontend**, no step-time debugger, and no structured execution-trace protocol. The UI must sit on top of (and extend) this toolchain — not replace the RTL or invent a second Python interpreter.

Canonical docs to read before coding:

- `README.md`
- `pycore/docs/architecture.md` (frames, RF, boot, traps, two-core)
- `pycore/docs/preprocessing_breakdown.md` (image-boot vs deprecated preprocess)
- `pycore/docs/bytecode_support.md` (what user programs may legally contain)
- `pycore/docs/tags.md`, `pycore/docs/object_model.md`
- `excore/docs/` if two-core mode is enabled

---

## 3. Product vision (approval checklist)

### 3.1 Must-have user experience

1. **Open the simulator** — one local command starts a web UI (browser).
2. **Load Python source** in either way:
   - Drag-and-drop a `.py` file from the user's machine into the editor pane.
   - Type / paste / edit source in a code editor in the browser.
3. **Configure a short run profile** (sensible defaults):
   - Entry function name (default: `managed_entry`).
   - Max cycles.
   - Core mode: single-core (`EXCORE_EN=0`) vs two-core (recoverable container traps via excore) when available.
4. **Click Run** — backend builds a PyCore image from the source, launches Verilator simulation, and streams or returns a structured execution trace + final result.
5. **See the result clearly**:
   - Pass / trap / timeout.
   - Decoded return value (tag + human-readable value when possible).
   - Cycle count / opcodes retired / CPO if available.
   - Host expected result when the entry returns `int`/`bool` (reuse `run_image_test` host path); show match/mismatch.
6. **Debug / visualize the run** (debugger-like):
   - Scrub or step through execution snapshots (at least per retired opcode; finer cycle detail is a plus).
   - Highlight the current bytecode / source line when mapping is available.
   - Visualize **operand stack** (RF\[32..95\] live window relative to TOS).
   - Visualize **call frames** (frame-stack descriptors in dmem `0x1C000`–`0x1FFFF`, plus locals window RF\[0..31\]).
   - Visualize **heap data structures** reachable from handles (lists/dicts/sets/tuples/strings/code objects/objects) with tag-aware decoding.
   - Show trap / mailbox events when two-core mode is on.

### 3.2 Explicit non-goals (v1)

- Not a full CPython debugger (no pdb, no CPython frame objects as source of truth).
- Not an FPGA bitstream / waveform viewer (GTKWave-style VCD browsing is optional later).
- Not supporting the full Python language — only what `bytecode_support.md` + image tooling accept. Unsupported constructs must fail at image-build with a clear UI error.
- Not rewriting RTL microarchitecture. Add **observation / trace hooks** only as needed.
- Not using deprecated `preprocess.py` for the primary path. Prefer **image-boot** (`image_from_source.py`).
- Not multi-user cloud hosting in v1 — local single-user tool is enough.
- Not pretty-printing every possible heap corruption edge case; best-effort decode with raw hex fallback is fine.

### 3.3 Success definition (human-approvable)

A reviewer can:

1. Start the UI with one documented command.
2. Drop in `pycore/programs/smoke_return.py` (or type an equivalent `managed_entry`), click Run, and see return `12` / INT.
3. Step a recursive or call-chain program (e.g. `img_recursion` / `call_chain`) and watch call frames and stack grow/shrink.
4. Run a small list/dict program and expand the container visualization as elements change across steps.
5. On unsupported syntax/opcodes, get a readable build error in the UI, not a silent hang.

---

## 4. Recommended architecture

Keep three layers. Do not collapse RTL, orchestration, and UI into one script.

```text
┌─────────────────────────────────────────────────────────────┐
│  Browser UI (editor + debugger panes)                       │
│  - Monaco/CodeMirror editor, drag-drop                      │
│  - Timeline / step controls                                 │
│  - Panels: Result, Stack, Frames, Heap, RF, Trace log       │
└───────────────────────────▲─────────────────────────────────┘
                            │ HTTP + WebSocket (JSON)
┌───────────────────────────┴─────────────────────────────────┐
│  Local orchestration server (Python 3.14)                   │
│  - Validate / build image via image_from_source             │
│  - Optional host expected-result via run_image_test helpers │
│  - Invoke Verilator sim with trace enabled                  │
│  - Parse sim stdout/trace → SessionTrace model              │
│  - Serve session + step snapshots to UI                     │
└───────────────────────────▲─────────────────────────────────┘
                            │ subprocess / files
┌───────────────────────────┴─────────────────────────────────┐
│  PyCore sim (Verilator) + new/extended trace hooks          │
│  - Image-boot top (single or two-core)                      │
│  - Emits structured per-opcode (and optional per-cycle) log │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 Suggested repo layout (implementer may adjust names, not responsibilities)

```text
sim_ui/                      # or pycore/sim_ui/
  README.md                  # how to run the UI
  server/                    # FastAPI (or similar) orchestration
    app.py
    image_build.py           # thin wrapper over image_from_source
    sim_runner.py            # Verilator invoke + artifact dirs
    trace_parse.py           # lines → SessionTrace
    decode.py                # tag/entry → JSON-friendly values
    models.py                # pydantic / dataclasses
  web/                       # frontend (Vite + React/TS preferred)
    ...
  fixtures/                  # tiny demo programs for UI smoke
Makefile additions           # `make sim-ui` / `make sim-ui-dev`
planning/… (this doc)        # stays as the product brief
```

**Stack guidance (defaults if no strong repo preference):**

- Backend: Python 3.14 + FastAPI + uvicorn.
- Frontend: Vite + React + TypeScript.
- Editor: Monaco or CodeMirror 6.
- No new heavyweight design system; keep the UI utilitarian and debugger-clear (dense but readable). This is a developer tool, not a marketing landing page — prioritize information density and step clarity over brand hero layouts.

---

## 5. Execution & trace contract (the hard part)

Today’s `tb_pycore_runfile` only reports the final return and a coarse RF shadow. A debugger needs a **time series**. Implement a structured trace.

### 5.1 Trace design principles

1. **Hardware-faithful:** values come from sim/RTL observation, not from re-interpreting Python on the host (except optional expected-result compare).
2. **Opcode-primary timeline:** v1 scrubber steps are “opcode retired” (or “entered S_WB / equivalent”). Optional sub-steps for multi-cycle container ops can be phase markers.
3. **Self-describing lines** the existing `cosim_trace.py` style can grow into, e.g. space-separated `key=value` plus a JSON snapshot mode for the UI.
4. **Bounded size:** large programs must not explode RAM. Caps:
   - max cycles (user-set),
   - max retained snapshots (e.g. 50k),
   - optional “keypoints only” mode (CALL/RETURN/trap/container mutate).
5. **Decode on the server** into UI-friendly JSON so the browser does not reimplement tag layouts.

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
  "excore": null,
  "stdout_like": []
}
```

Notes:

- Full RF every step is OK for small runs; for larger runs prefer stack + locals + dirty-RF deltas.
- `heap_delta` can be “handles touched this step”; a separate endpoint can expand a handle into a full decoded object graph on demand.
- Function names: best-effort from image metadata / `co_names` / source map; fall back to code-object address.

### 5.3 RTL / TB work required

Implement observation without changing architectural behavior:

1. Prefer extending the **image-boot testbench path** used by `PYCORE_IMAGE_RUN` / two-core tops rather than investing in legacy `tb_pycore_runfile` + `preprocess.py`.
2. Add a **trace enable** plus output path (plusarg, parameter, or env-selected file).
3. At a stable point each opcode (e.g. end of writeback / when PC advances), dump:
   - cycle, pc, opcode, oparg
   - tos / locals_base / tos_base
   - RF entries that are in the live locals+stack window (or full 96)
   - frame-stack top pointer / depth if available
   - trap_code when asserted; mailbox req/res summary when `EXCORE_EN=1`
4. On program end: emit final return entry, PASS/FAIL/TRAP/TIMEOUT reason (machine-readable).
5. Keep `$display` human logs, but make the **file trace** the API the server parses.

If hierarchical TB peeks (`dut.core.*`) are already the house style, continue that pattern for v1 rather than a large DPI redesign — but isolate peek logic in one TB/helper so it can be replaced later.

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
│ Mode · entry · max cycles    │ return value                   │
├──────────────────────────────┼────────────────────────────────┤
│ Source editor                │ Visualizations (tabbed/split)  │
│ (drag-drop target overlay)   │  • Operand stack               │
│                              │  • Call frames                 │
│ Disassembly (optional pane)  │  • Heap / object inspector     │
│                              │  • RF raw (advanced)           │
│                              │  • Trace / events              │
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

**Traps:** banner with code name from architecture taxonomy; freeze scrubber at trap step.

### 6.4 Demo programs

Ship UI-loadable demos (buttons or examples menu), reusing existing programs where possible:

- `smoke_return.py` — trivial return
- call / recursion example — frames
- list/dict build + index — heap
- a program that traps (type or mem fault) — trap UX
- optional two-core grow example when excore mode enabled

---

## 7. Backend API sketch

Implement roughly these endpoints (names flexible; keep the responsibilities):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Python version, verilator present, repo root |
| `POST` | `/api/sessions` | Body: source text, entry, max_cycles, mode → create session, build+run (or async job) |
| `GET` | `/api/sessions/{id}` | Status, result summary, error |
| `GET` | `/api/sessions/{id}/steps/{n}` | Snapshot n |
| `GET` | `/api/sessions/{id}/steps?from=&to=` | Bulk range for scrubbing |
| `GET` | `/api/sessions/{id}/heap/{addr}` | Expanded object decode at step (query `step=`) |
| `GET` | `/api/sessions/{id}/disasm` | PC → mnemonic listing |
| `WS` | `/api/sessions/{id}/events` | Optional: build/sim progress streaming |

Use a per-session temp dir under `build/sim_ui/<session_id>/` for hex, meta, trace, logs. Clean up old sessions (TTL or LRU).

**Security (local tool, still be sane):**

- Do not `eval` user source on the server except through the existing image/host helpers.
- Cap source size and max_cycles.
- Run Verilator with timeouts; kill runaway sims.
- No arbitrary path reads from the client beyond the session sandbox.

---

## 8. Integration with existing Make / Python tools

### 8.1 Image build

Primary:

```text
Python source (text)
  → image_from_source.build_image_from_source_text / write_image_outputs
  → program.hex, dmem.hex, string_mem.hex, image.meta
```

Validate unsupported opcodes the same way tooling already does; surface stderr/exceptions to the UI.

Entry convention: match repo programs — define `managed_entry()` (or user-selected name) and typically call it at module level for image-boot, consistent with `img_*` fixtures. Document this in the UI help strip.

### 8.2 Simulation

Wrap the same Verilator tops the Makefile uses for image runs (single-core and, when selected, two-core). Prefer invoking a **new Make target or Python runner** dedicated to traced runs rather than scraping unrelated test PASS lines.

Add something like:

```bash
make pycore-sim-trace \
  RUN_SOURCE=... \
  TRACE_JSONL=build/sim_ui/.../trace.jsonl \
  MAX_CYCLES=...
```

…or a Python equivalent used by both Make and the server.

### 8.3 Decoding

Centralize tag/entry decoding in one Python module (extend `pycore/tools/encoding.py` / heap helpers rather than duplicating constants). Mirror layouts in:

- `pycore/docs/tags.md`
- `heap_image.py` / architecture memory map
- frame descriptor layout in `architecture.md`

### 8.4 Python version

Hard-require **Python 3.14** for the server process (same gate as image tools). Health endpoint should fail clearly if wrong.

---

## 9. Phased delivery plan

Implement in phases so a partial PR is still reviewable.

### Phase A — Vertical slice (approve-to-demo)

- Server can build image from pasted source and run traced sim for a trivial program.
- Trace contains at least: step, cycle, pc, opcode, stack list, return summary.
- Minimal web UI: editor, Run, result panel, stack panel, step buttons.
- Works for `managed_entry` returning a small INT.

**Exit criteria:** drag/paste `smoke_return.py` → Run → see `12`, step through a few opcodes with stack updates.

### Phase B — Frames + disassembly + errors

- Call frame panel with depth and locals.
- Disassembly pane synced to PC.
- Image-build / trap / timeout errors polished in UI.
- Timeline scrubber.

**Exit criteria:** recursion/call-chain demo shows nested frames; trap demo shows code name.

### Phase C — Heap inspector + two-core events

- On-demand heap decode for LIST/DICT/SET/TUPLE/STR/CODE/OBJECT.
- Highlight mutated handles across steps.
- Optional two-core mode with mailbox/trap event lane in the trace view.

**Exit criteria:** list/dict demo inspectable; grow trap path visible when excore enabled.

### Phase D — Polish

- Examples menu, keyboard shortcuts (Run, Step), session persistence in memory only.
- Trace size controls / keypoint mode.
- Docs: `sim_ui/README.md` + link from root `README.md`.
- Basic automated tests: decode unit tests, trace parser tests, one end-to-end “build+parse smoke” if CI can run Verilator.

---

## 10. Testing requirements for the implementing agent

1. **Unit tests** for tag/entry decode and trace parser (no Verilator).
2. **Golden trace fixture** (checked-in small JSONL) to lock UI/server parsing.
3. **Manual/scripted e2e:** run server, POST session with smoke program, assert return INT 12.
4. Do **not** weaken existing `make pycore-test` / image differentials; new hooks must be off-by-default or unused by existing TBs.
5. If RTL/TB changes land, run the relevant image tests (`pycore-img-smoke` at minimum; more if frame/heap hooks touch shared modules).

---

## 11. Implementation constraints & risks

| Risk | Mitigation |
| --- | --- |
| Hierarchical signal peeks brittle across RTL refactors | Isolate in one TB/trace module; prefer stable architectural state (RF, PC, tos, frame ptr) |
| Trace files huge | Caps, deltas, keypoint mode |
| Line mapping incomplete | Ship PC/disasm highlight first |
| `run-file` preprocess path diverges from image-boot | Do not build the UI on `preprocess.py` |
| Two-core complexity | Phase A/B single-core; Phase C optional toggle |
| Wrong Python version on host | Health check + README; reuse tooling’s 3.14 gate |
| Security of `exec` in host expected-result | Reuse existing helper; only for compare; never trust client paths |

---

## 12. Deliverables checklist (agent definition of done)

- [ ] `sim_ui/` (or equivalent) with server + web client
- [ ] Make/docs entry point: one command to launch
- [ ] Image-boot based run path with structured trace output
- [ ] UI: load source (drag/drop + edit), Run, result, step/scrub
- [ ] Panels: stack, frames, heap inspector (per phase), basic RF/advanced raw
- [ ] Clear errors for unsupported Python / traps / timeouts
- [ ] Tests for decode + trace parse; smoke path documented
- [ ] Root or `sim_ui` README section describing UX and limits (bytecode subset, Python 3.14)
- [ ] No reliance on deprecated preprocess as the primary path
- [ ] This planning doc updated with “Implemented” notes / deviations only if approval changes scope

---

## 13. Prompt for the implementing agent (copy-paste kickoff)

After a human approves this document, an implementing agent should treat the following as the task statement:

```text
Implement the PyCore Interactive Simulator & Debugger UI described in
`planning/pycore_sim_debugger_ui_prompt.md`.

Read that document fully, then read README.md and the pycore docs it cites.
Execute Phase A first and stop for review if Phase A alone is a large change;
otherwise continue through Phase B. Do not start Phase C/D unless Phase A/B
are solid or the user asks to go further.

Constraints:
- Prefer image_from_source / image-boot tops; do not make preprocess.py primary.
- Require Python 3.14 for orchestration.
- Add RTL/TB observation hooks only as needed for tracing; do not change
  architectural execution semantics.
- Keep existing make test targets green.
- Put new code under a dedicated sim_ui (or pycore/sim_ui) tree plus minimal
  Makefile/README wiring.
- Match the UX must-haves in §3.1 and the success definition in §3.3.

Acceptance for the first PR:
- One-command local UI launch
- Paste/drag Python with managed_entry, Run, see decoded return
- Step through snapshots with operand stack visualization
- Document how to run it and what Python subset is supported
```

---

## 14. Reviewer notes (for you)

Approve / amend before implementation, especially:

1. **Scope cut:** Is Phase A+B enough for the first build, or must heap + two-core land immediately?
2. **UI stack:** FastAPI + React/Vite default OK, or do you want a simpler single-page + Starlette/Flask approach?
3. **Trace fidelity:** Per-opcode snapshots OK, or do you need true per-cycle / per-container-phase stepping in v1?
4. **Legacy `make run-file`:** Leave as-is (recommended), or also migrate it to image-boot as drive-by work? (Drive-by not required for this feature.)
5. **Hosting:** Local-only confirmed?

Mark decisions at the top of this file when approved, then hand the §13 kickoff prompt to an implementing agent.
