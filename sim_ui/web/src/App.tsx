import { useEffect, useMemo, useState, type DragEvent } from "react";
import CodeMirror from "@uiw/react-codemirror";
import { python } from "@codemirror/lang-python";
import { oneDark } from "@codemirror/theme-one-dark";
import type {
  DisasmRow,
  EndInfo,
  EventInfo,
  Example,
  SessionResult,
  StepSnapshot,
  TaggedValue,
} from "./types";

const DEFAULT_SOURCE = `def managed_entry():
    return 12


managed_entry()
`;

type Tab = "stack" | "frames" | "excore" | "heap" | "disasm" | "help";

function EntryView({
  entry,
  onInspect,
}: {
  entry: TaggedValue;
  onInspect?: (addr: number) => void;
}) {
  const clickable = entry.addr != null && onInspect;
  return (
    <div
      className="entry"
      title={entry.raw}
      onClick={() => clickable && onInspect(entry.addr!)}
      style={clickable ? { cursor: "pointer" } : undefined}
    >
      <span className="tag">{entry.tag}</span>
      {entry.kind ? <span className="tag">{entry.kind}</span> : null}
      <span>{entry.display}</span>
      {entry.contaminated ? <span className="pill warn">contam</span> : null}
    </div>
  );
}

export default function App() {
  const [source, setSource] = useState(DEFAULT_SOURCE);
  const [entry, setEntry] = useState("managed_entry");
  const [maxCycles, setMaxCycles] = useState(200000);
  const [examples, setExamples] = useState<Example[]>([]);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [end, setEnd] = useState<EndInfo | null>(null);
  const [expectedHost, setExpectedHost] = useState<string | null>(null);
  const [steps, setSteps] = useState<StepSnapshot[]>([]);
  const [events, setEvents] = useState<EventInfo[]>([]);
  const [disasm, setDisasm] = useState<DisasmRow[]>([]);
  const [stepIdx, setStepIdx] = useState(0);
  const [tab, setTab] = useState<Tab>("stack");
  const [heapView, setHeapView] = useState<Record<string, unknown> | null>(null);
  const [health, setHealth] = useState<string>("…");

  useEffect(() => {
    fetch("/api/health")
      .then((r) => r.json())
      .then((h) => {
        setHealth(
          h.ok
            ? `ready · py ${h.python} · two-core`
            : `degraded · py ${h.python} · verilator=${h.verilator}`
        );
      })
      .catch(() => setHealth("unreachable"));
    fetch("/api/examples")
      .then((r) => r.json())
      .then(setExamples)
      .catch(() => undefined);
  }, []);

  const snap = steps[stepIdx] ?? null;
  const prev = stepIdx > 0 ? steps[stepIdx - 1] : null;

  const stackDelta = useMemo(() => {
    if (!snap) return { push: new Set<number>(), popFrom: 0 };
    const prevLen = prev?.stack.length ?? 0;
    const curLen = snap.stack.length;
    const push = new Set<number>();
    if (curLen > prevLen) {
      for (let i = prevLen; i < curLen; i++) push.add(i);
    }
    return { push, popFrom: Math.min(prevLen, curLen) };
  }, [snap, prev]);

  async function runSim() {
    setRunning(true);
    setError(null);
    setHeapView(null);
    try {
      const res = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          source,
          entry,
          max_cycles: maxCycles,
        }),
      });
      const data: SessionResult = await res.json();
      if (!res.ok) {
        throw new Error((data as { detail?: string }).detail || res.statusText);
      }
      if (data.status === "error") {
        setSessionId(data.id);
        setSteps([]);
        setEvents([]);
        setDisasm([]);
        setEnd(null);
        setError(data.error || "simulation failed");
        return;
      }
      setSessionId(data.id);
      setEnd(data.end ?? null);
      setExpectedHost(data.result?.expected?.host_display ?? null);
      setDisasm(data.disasm ?? []);
      const stepsRes = await fetch(`/api/sessions/${data.id}/steps`);
      const stepsJson = await stepsRes.json();
      setSteps(stepsJson.steps ?? []);
      setStepIdx(0);
      const evRes = await fetch(`/api/sessions/${data.id}/events`);
      const evJson = await evRes.json();
      setEvents(evJson.events ?? []);
      setTab("stack");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRunning(false);
    }
  }

  async function inspectAddr(addr: number) {
    if (!sessionId) return;
    setTab("heap");
    try {
      const res = await fetch(
        `/api/sessions/${sessionId}/heap/${addr}?step=${stepIdx}`
      );
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "heap decode failed");
      setHeapView(data);
    } catch (e) {
      setHeapView({ error: e instanceof Error ? e.message : String(e) });
    }
  }

  function onDrop(ev: DragEvent) {
    ev.preventDefault();
    const file = ev.dataTransfer.files?.[0];
    if (!file) return;
    file.text().then(setSource);
  }

  const statusClass =
    end?.status === "PASS"
      ? "ok"
      : end?.status === "FATAL_TRAP" || end?.status === "TIMEOUT"
        ? "danger"
        : "warn";

  return (
    <div className="app">
      <header className="toolbar">
        <div className="brand">PyCore Sim</div>
        <button className="primary" onClick={runSim} disabled={running}>
          {running ? "Running…" : "Run"}
        </button>
        <button
          onClick={() => setStepIdx((i) => Math.max(0, i - 1))}
          disabled={!steps.length || stepIdx <= 0}
        >
          Step ◀
        </button>
        <button
          onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
          disabled={!steps.length || stepIdx >= steps.length - 1}
        >
          Step ▶
        </button>
        <label>
          Entry
          <input value={entry} onChange={(e) => setEntry(e.target.value)} />
        </label>
        <label>
          Max cycles
          <input
            type="number"
            value={maxCycles}
            min={1000}
            max={5000000}
            step={1000}
            onChange={(e) => setMaxCycles(Number(e.target.value))}
          />
        </label>
        <label>
          Example
          <select
            defaultValue=""
            onChange={(e) => {
              const ex = examples.find((x) => x.id === e.target.value);
              if (ex) setSource(ex.source);
            }}
          >
            <option value="" disabled>
              Load demo…
            </option>
            {examples.map((ex) => (
              <option key={ex.id} value={ex.id}>
                {ex.title}
              </option>
            ))}
          </select>
        </label>
        <div className="status-pill">
          <span className="pill muted">{health}</span>
          {end ? <span className={`pill ${statusClass}`}>{end.status}</span> : null}
          {snap ? (
            <span
              className={`pill ${snap.mem_owner === "EXCORE" ? "owner-ex" : "owner-py"}`}
            >
              {snap.mem_owner}
            </span>
          ) : null}
          {end?.return_value ? (
            <span className="pill">
              ret {end.return_value.tag} {end.return_value.display}
            </span>
          ) : null}
          {end ? (
            <span className="pill">
              {end.cycles} cyc · {end.opcodes} ops
              {end.trap_req_count ? ` · ${end.trap_req_count} mailbox` : ""}
            </span>
          ) : null}
          {expectedHost != null ? (
            <span
              className={`pill ${
                end?.expected_match === false
                  ? "danger"
                  : end?.expected_match
                    ? "ok"
                    : ""
              }`}
            >
              host {expectedHost}
              {end?.expected_match === true
                ? " ✓"
                : end?.expected_match === false
                  ? " ✗"
                  : ""}
            </span>
          ) : null}
        </div>
      </header>

      <div className="main">
        <section
          className="panel"
          onDragOver={(e) => e.preventDefault()}
          onDrop={onDrop}
        >
          <div className="panel-head">
            <span>Source</span>
            <span>{sessionId ? `session ${sessionId}` : "no session"}</span>
          </div>
          <div className="drop-hint">
            Drag a <code>.py</code> file here, or edit below. Entry must be{" "}
            <code>{entry}()</code> (image-boot / two-core).
          </div>
          <div className="editor-wrap">
            <CodeMirror
              value={source}
              height="100%"
              theme={oneDark}
              extensions={[python()]}
              onChange={(v) => setSource(v)}
              basicSetup={{ lineNumbers: true, foldGutter: true }}
            />
          </div>
          {error ? <div className="error-banner">{error}</div> : null}
        </section>

        <section className="panel">
          <div className="tabs">
            {(
              [
                ["stack", "Stack"],
                ["frames", "Frames"],
                ["excore", "Excore"],
                ["heap", "Heap"],
                ["disasm", "Disasm"],
                ["help", "Help"],
              ] as const
            ).map(([id, label]) => (
              <button
                key={id}
                className={tab === id ? "active" : ""}
                onClick={() => setTab(id)}
              >
                {label}
              </button>
            ))}
          </div>
          <div className="viz">
            {!snap && tab !== "help" ? (
              <p className="muted">
                Click <strong>Run</strong> to build an image and step a two-core
                simulation.
              </p>
            ) : null}

            {tab === "stack" && snap ? (
              <>
                <p className="muted">
                  PC {snap.pc} · {snap.opcode} {snap.oparg} · TOS base 32 →{" "}
                  {snap.tos} (top at bottom of list)
                </p>
                <ul className="stack-list">
                  {snap.stack.map((e, i) => (
                    <li key={i}>
                      <EntryView
                        entry={e}
                        onInspect={inspectAddr}
                      />
                    </li>
                  ))}
                </ul>
                {!snap.stack.length ? <p className="muted">Stack empty</p> : null}
                {stackDelta.push.size > 0 ? (
                  <p className="muted">Δ push {stackDelta.push.size}</p>
                ) : null}
              </>
            ) : null}

            {tab === "frames" && snap ? (
              <ul className="frame-list">
                {snap.frames.map((fr, i) => (
                  <li key={i} className="frame">
                    <div>
                      <strong>
                        {fr.current ? "current" : `saved#${fr.depth}`}
                      </strong>{" "}
                      {fr.func ?? ""} · locals_base={fr.locals_base}
                      {fr.pc_return != null ? ` · ret_pc=${fr.pc_return}` : ""}
                    </div>
                    {fr.current && Object.keys(fr.locals).length ? (
                      <div className="locals">
                        {Object.entries(fr.locals).map(([name, val]) => (
                          <div key={name}>
                            {name} = {val.tag} {val.display}
                            {val.contaminated ? " [contam]" : ""}
                          </div>
                        ))}
                      </div>
                    ) : null}
                  </li>
                ))}
              </ul>
            ) : null}

            {tab === "excore" ? (
              <>
                <p className="muted">
                  Memory owner chip follows the scrubber. Mailbox events are
                  recoverable trap handoffs (LIST_*/DICT_*/SET_* including
                  DICT_UPDATE=19 / DICT_MERGE=20).
                </p>
                {snap ? (
                  <p>
                    Owner:{" "}
                    <span
                      className={`pill ${
                        snap.mem_owner === "EXCORE" ? "owner-ex" : "owner-py"
                      }`}
                    >
                      {snap.mem_owner}
                    </span>
                    {snap.mem_owner === "PYCORE" ? " (excore parked)" : " (grant active)"}
                  </p>
                ) : null}
                <ul className="event-list">
                  {events.map((ev, i) => (
                    <li key={i} className={`event ${ev.kind}`}>
                      cyc {ev.cycle} · step {ev.step} · {ev.kind}{" "}
                      <strong>{ev.code_name ?? ev.code}</strong> ({ev.code}) ·{" "}
                      {ev.opcode} · owner {ev.mem_owner}
                    </li>
                  ))}
                </ul>
                {!events.length ? (
                  <p className="muted">No mailbox events in this run.</p>
                ) : null}
              </>
            ) : null}

            {tab === "heap" ? (
              <>
                <p className="muted">
                  Click a stack/local handle with an address to inspect. Decode
                  uses the end-of-run dmem image (heap mutations after the
                  selected step may appear). Contamination is sticky on
                  MUT_COLLEC.
                </p>
                {heapView ? (
                  <pre className="entry" style={{ whiteSpace: "pre-wrap" }}>
                    {JSON.stringify(heapView, null, 2)}
                  </pre>
                ) : (
                  <p className="muted">No object selected.</p>
                )}
                {snap ? (
                  <ul className="heap-list" style={{ marginTop: "0.75rem" }}>
                    {snap.stack
                      .filter((e) => e.addr != null)
                      .map((e, i) => (
                        <li key={i}>
                          <button onClick={() => inspectAddr(e.addr!)}>
                            Inspect {e.display}
                          </button>
                        </li>
                      ))}
                  </ul>
                ) : null}
              </>
            ) : null}

            {tab === "disasm" ? (
              <div className="disasm">
                {disasm
                  .filter((row) => !row.is_cache)
                  .map((row) => (
                    <div
                      key={row.pc}
                      className={`disasm-row ${
                        snap && row.pc === snap.pc ? "active" : ""
                      }`}
                    >
                      {row.text}
                    </div>
                  ))}
              </div>
            ) : null}

            {tab === "help" ? (
              <div className="help">
                <p>
                  This UI always runs the <strong>two-core</strong> system
                  (pycore + excore) via image-boot. Define{" "}
                  <code>managed_entry()</code> and call it at module level.
                </p>
                <p>
                  Supported Python is the PyCore bytecode subset — see{" "}
                  <code>pycore/docs/bytecode_support.md</code>. Unsupported
                  syntax fails at image build with a readable error.
                </p>
                <p>
                  Launch (Docker-first): <code>make docker-build && make docker-sim-ui</code>{" "}
                  then open <code>http://localhost:8000</code>.
                </p>
              </div>
            ) : null}
          </div>
        </section>
      </div>

      <footer className="scrubber">
        <div className="scrubber-controls">
          <span className="muted">
            {steps.length
              ? `Step ${stepIdx} / ${steps.length - 1}`
              : "No trace"}
            {snap
              ? ` · cycle ${snap.cycle} · depth ${snap.frame_depth} · heap_ptr ${snap.heap_ptr}`
              : ""}
          </span>
          {end?.trap_name ? (
            <span className="pill danger">trap {end.trap_name}</span>
          ) : null}
        </div>
        <input
          type="range"
          min={0}
          max={Math.max(0, steps.length - 1)}
          value={stepIdx}
          disabled={!steps.length}
          onChange={(e) => setStepIdx(Number(e.target.value))}
        />
      </footer>
    </div>
  );
}
