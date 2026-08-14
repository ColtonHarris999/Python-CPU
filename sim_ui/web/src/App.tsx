import { useCallback, useEffect, useMemo, useState, type DragEvent } from "react";
import CodeMirror from "@uiw/react-codemirror";
import { python } from "@codemirror/lang-python";
import { oneDark } from "@codemirror/theme-one-dark";
import type {
  DisasmRow,
  EndInfo,
  EventInfo,
  Example,
  HeapDelta,
  SessionResult,
  StepSnapshot,
  TaggedValue,
} from "./types";

const DEFAULT_SOURCE = `def managed_entry():
    return 12


managed_entry()
`;

type Tab = "stack" | "frames" | "excore" | "heap" | "rf" | "disasm" | "help";

function EntryView({
  entry,
  onInspect,
  highlight,
}: {
  entry: TaggedValue;
  onInspect?: (addr: number) => void;
  highlight?: boolean;
}) {
  const clickable = entry.addr != null && onInspect;
  return (
    <div
      className={`entry${highlight ? " delta-push" : ""}`}
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

async function waitForSession(id: string): Promise<SessionResult> {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const wsUrl = `${proto}://${location.host}/api/sessions/${id}/stream`;

  const viaPoll = async () => {
    for (let i = 0; i < 600; i++) {
      const res = await fetch(`/api/sessions/${id}`);
      const data: SessionResult = await res.json();
      if (data.status === "ready" || data.status === "error") return data;
      await new Promise((r) => setTimeout(r, 400));
    }
    throw new Error("timed out waiting for simulation");
  };

  try {
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(wsUrl);
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          try {
            ws.close();
          } catch {
            /* ignore */
          }
          reject(new Error("ws timeout"));
        }
      }, 180_000);
      ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.t === "done" || msg.t === "error") {
            if (!settled) {
              settled = true;
              clearTimeout(timer);
              ws.close();
              resolve();
            }
          }
        } catch {
          /* ignore */
        }
      };
      ws.onerror = () => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(new Error("ws error"));
        }
      };
    });
    const res = await fetch(`/api/sessions/${id}`);
    return res.json();
  } catch {
    return viaPoll();
  }
}

export default function App() {
  const [source, setSource] = useState(DEFAULT_SOURCE);
  const [entry, setEntry] = useState("managed_entry");
  const [maxCycles, setMaxCycles] = useState(200000);
  const [keypointMode, setKeypointMode] = useState(false);
  const [examples, setExamples] = useState<Example[]>([]);
  const [running, setRunning] = useState(false);
  const [phase, setPhase] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
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
  const scrubberFrozen = end?.status === "FATAL_TRAP";

  const stackDelta = useMemo(() => {
    if (!snap) return { push: new Set<number>() };
    const prevLen = prev?.stack.length ?? 0;
    const curLen = snap.stack.length;
    const push = new Set<number>();
    if (curLen > prevLen) {
      for (let i = prevLen; i < curLen; i++) push.add(i);
    }
    return { push };
  }, [snap, prev]);

  const loadReadySession = useCallback(async (data: SessionResult) => {
    setSessionId(data.id);
    setEnd(data.end ?? null);
    setExpectedHost(data.result?.expected?.host_display ?? null);
    setDisasm(data.disasm ?? []);
    setKeypointMode(Boolean(data.keypoint_mode ?? data.result?.keypoint_mode));
    if (data.status === "error") {
      setSteps([]);
      setEvents([]);
      setError(data.error || "simulation failed");
      return;
    }
    const stepsRes = await fetch(`/api/sessions/${data.id}/steps`);
    const stepsJson = await stepsRes.json();
    setSteps(stepsJson.steps ?? []);
    setStepIdx(0);
    const evRes = await fetch(`/api/sessions/${data.id}/events`);
    const evJson = await evRes.json();
    setEvents(evJson.events ?? []);
    setStale(false);
    setTab("stack");
  }, []);

  async function runSim() {
    setRunning(true);
    setError(null);
    setHeapView(null);
    setPhase("starting");
    setEnd(null);
    try {
      const res = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          source,
          entry,
          max_cycles: maxCycles,
          keypoint_mode: keypointMode,
          background: true,
        }),
      });
      const data: SessionResult = await res.json();
      if (!res.ok) {
        throw new Error(
          (data as { detail?: string }).detail || res.statusText
        );
      }
      setSessionId(data.id);
      setPhase(data.phase || "running");

      // Poll phase while waiting.
      const poll = window.setInterval(async () => {
        try {
          const r = await fetch(`/api/sessions/${data.id}`);
          const s: SessionResult = await r.json();
          if (s.phase) setPhase(s.phase);
        } catch {
          /* ignore */
        }
      }, 500);

      const final = await waitForSession(data.id);
      window.clearInterval(poll);
      setPhase(final.phase || final.status);
      await loadReadySession(final);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRunning(false);
      setPhase(null);
    }
  }

  async function toggleKeypoint(next: boolean) {
    setKeypointMode(next);
    if (!sessionId || end == null) return;
    const res = await fetch(`/api/sessions/${sessionId}/keypoint`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: next }),
    });
    if (!res.ok) return;
    const stepsRes = await fetch(`/api/sessions/${sessionId}/steps`);
    const stepsJson = await stepsRes.json();
    setSteps(stepsJson.steps ?? []);
    setStepIdx(0);
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
    file.text().then((t) => {
      setSource(t);
      setStale(true);
    });
  }

  useEffect(() => {
    function onKey(ev: KeyboardEvent) {
      const target = ev.target as HTMLElement | null;
      const typing =
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable ||
          target.closest(".cm-editor"));
      if (typing && ev.key !== "F5") return;

      if (ev.key === "F5" || ((ev.key === "Enter" || ev.key === "r") && (ev.metaKey || ev.ctrlKey))) {
        ev.preventDefault();
        if (!running) void runSim();
        return;
      }
      if (scrubberFrozen || !steps.length) return;
      if (ev.key === "ArrowRight" || ev.key === "j") {
        ev.preventDefault();
        setStepIdx((i) => Math.min(steps.length - 1, i + 1));
      } else if (ev.key === "ArrowLeft" || ev.key === "k") {
        ev.preventDefault();
        setStepIdx((i) => Math.max(0, i - 1));
      } else if (ev.key === "Home") {
        setStepIdx(0);
      } else if (ev.key === "End") {
        setStepIdx(steps.length - 1);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [running, steps.length, scrubberFrozen]);

  const statusClass =
    end?.status === "PASS"
      ? "ok"
      : end?.status === "FATAL_TRAP" || end?.status === "TIMEOUT"
        ? "danger"
        : "warn";

  const contamBulkNote = (snap?.heap_delta || []).find((h) => h.routing_note);

  return (
    <div className="app">
      <header className="toolbar">
        <div className="brand">PyCore Sim</div>
        <button className="primary" onClick={runSim} disabled={running}>
          {running ? `Running…${phase ? ` (${phase})` : ""}` : "Run"}
        </button>
        <button
          onClick={() => setStepIdx((i) => Math.max(0, i - 1))}
          disabled={!steps.length || stepIdx <= 0 || scrubberFrozen}
          title="Step back (← / k)"
        >
          Step ◀
        </button>
        <button
          onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
          disabled={!steps.length || stepIdx >= steps.length - 1 || scrubberFrozen}
          title="Step forward (→ / j)"
        >
          Step ▶
        </button>
        <label>
          Entry
          <input
            value={entry}
            onChange={(e) => {
              setEntry(e.target.value);
              setStale(true);
            }}
          />
        </label>
        <label>
          Max cycles
          <input
            type="number"
            value={maxCycles}
            min={1000}
            max={5000000}
            step={1000}
            onChange={(e) => {
              setMaxCycles(Number(e.target.value));
              setStale(true);
            }}
          />
        </label>
        <label title="Keep CALL/RETURN/container/trap steps only">
          <input
            type="checkbox"
            checked={keypointMode}
            onChange={(e) => void toggleKeypoint(e.target.checked)}
          />{" "}
          Keypoints
        </label>
        <label>
          Example
          <select
            defaultValue=""
            onChange={(e) => {
              const ex = examples.find((x) => x.id === e.target.value);
              if (ex) {
                setSource(ex.source);
                setStale(true);
              }
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
          {stale ? <span className="pill warn">edited</span> : null}
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
            Drag a <code>.py</code> file here. Entry must be <code>{entry}()</code>.
            Shortcuts: Ctrl/⌘+Enter run · ←/→ or j/k step · F5 run.
          </div>
          <div className="editor-wrap">
            <CodeMirror
              value={source}
              height="100%"
              theme={oneDark}
              extensions={[python()]}
              onChange={(v) => {
                setSource(v);
                setStale(true);
              }}
              basicSetup={{ lineNumbers: true, foldGutter: true }}
            />
          </div>
          {error ? <div className="error-banner">{error}</div> : null}
          {end?.status === "FATAL_TRAP" ? (
            <div className="error-banner">
              Fatal trap {end.trap_name ?? end.trap_code} — scrubber frozen at last
              snapshot.
            </div>
          ) : null}
        </section>

        <section className="panel">
          <div className="tabs">
            {(
              [
                ["stack", "Stack"],
                ["frames", "Frames"],
                ["excore", "Excore"],
                ["heap", "Heap"],
                ["rf", "RF"],
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
                  PC {snap.pc} · {snap.opcode} {snap.oparg} · TOS {snap.tos_base ?? 32}→
                  {snap.tos}
                  {snap.keypoint ? " · keypoint" : ""}
                </p>
                <ul className="stack-list">
                  {snap.stack.map((e, i) => (
                    <li key={i}>
                      <EntryView
                        entry={e}
                        onInspect={inspectAddr}
                        highlight={stackDelta.push.has(i)}
                      />
                    </li>
                  ))}
                </ul>
                {!snap.stack.length ? <p className="muted">Stack empty</p> : null}
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
                    {Object.keys(fr.locals).length ? (
                      <div className="locals">
                        {Object.entries(fr.locals).map(([name, val]) => (
                          <div
                            key={name}
                            style={val.addr != null ? { cursor: "pointer" } : undefined}
                            onClick={() => val.addr != null && inspectAddr(val.addr)}
                          >
                            {name} = {val.tag}
                            {val.kind ? `/${val.kind}` : ""} {val.display}
                            {val.contaminated ? " [contam]" : ""}
                          </div>
                        ))}
                      </div>
                    ) : (
                      <div className="locals muted">no named locals</div>
                    )}
                  </li>
                ))}
              </ul>
            ) : null}

            {tab === "excore" ? (
              <>
                <p className="muted">
                  Recoverable traps hand off to excore (LIST_*/DICT_*/SET_* including
                  DICT_UPDATE=19 / DICT_MERGE=20). Contaminated bulk may stay on pycore.
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
                {contamBulkNote ? (
                  <p className="pill warn">{contamBulkNote.routing_note}</p>
                ) : null}
                <ul className="event-list">
                  {events.map((ev, i) => (
                    <li key={i} className={`event ${ev.kind}`}>
                      cyc {ev.cycle} · step {ev.step} · {ev.kind}{" "}
                      <strong>{ev.code_name ?? ev.code}</strong> ({ev.code}) ·{" "}
                      {ev.opcode} · owner {ev.mem_owner}
                      {ev.entries?.length ? (
                        <div className="locals">
                          entries:{" "}
                          {ev.entries.map((e) => e.display).join(", ")}
                        </div>
                      ) : null}
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
                  Roots visible on this step (live headers). Full object expand uses
                  end-of-run dmem. Contamination is sticky on MUT_COLLEC.
                </p>
                {snap?.heap_delta?.length ? (
                  <ul className="heap-list">
                    {snap.heap_delta.map((h: HeapDelta, i) => (
                      <li key={i} className="entry">
                        <button onClick={() => inspectAddr(h.addr_int)}>
                          {h.summary}
                          {h.contaminated ? " [contam]" : ""}
                        </button>
                        {h.routing_note ? (
                          <div className="muted">{h.routing_note}</div>
                        ) : null}
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="muted">No heap roots on this step.</p>
                )}
                {heapView ? (
                  <pre className="entry" style={{ whiteSpace: "pre-wrap", marginTop: "0.75rem" }}>
                    {JSON.stringify(heapView, null, 2)}
                  </pre>
                ) : null}
              </>
            ) : null}

            {tab === "rf" && snap ? (
              <>
                <p className="muted">
                  Live RF window: locals base {snap.locals_base} + operand stack
                  [{snap.tos_base ?? 32}..{snap.tos}).
                </p>
                <ul className="heap-list">
                  {Object.entries(snap.rf || {})
                    .sort((a, b) => Number(a[0]) - Number(b[0]))
                    .map(([idx, val]) => (
                      <li key={idx}>
                        <EntryView entry={val} onInspect={inspectAddr} />
                        <span className="muted"> rf[{idx}]</span>
                      </li>
                    ))}
                </ul>
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
                  Always <strong>two-core</strong> (pycore + excore) via image-boot.
                  Define <code>managed_entry()</code> and call it at module level.
                </p>
                <p>
                  Subset: <code>pycore/docs/bytecode_support.md</code>. Unsupported
                  syntax fails at image build with an error banner.
                </p>
                <p>
                  Launch: <code>make docker-build && make docker-sim-ui</code> →{" "}
                  <code>http://localhost:8000</code>
                </p>
                <p>
                  Shortcuts: <code>Ctrl/⌘+Enter</code> or <code>F5</code> Run ·{" "}
                  <code>←/→</code> or <code>j/k</code> step · Keypoints filters to
                  calls/containers/traps.
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
            {keypointMode ? " · keypoint mode" : ""}
            {scrubberFrozen ? " · frozen" : ""}
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
          disabled={!steps.length || scrubberFrozen}
          onChange={(e) => setStepIdx(Number(e.target.value))}
        />
      </footer>
    </div>
  );
}
