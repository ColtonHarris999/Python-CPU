# Paper / systems documentation

Near-complete PyCore subsystems get a LaTeX note here so we can pull prose,
figures, and tradeoff tables into the research paper without mining RTL comments
or planning markdown.

## Layout

| Path | Topic |
| --- | --- |
| `systems/architecture_overview.tex` | Full pycore+excore component map, paper section skeleton, system diagram, core staging FSM |
| `systems/call_fsm.tex` | `S_CALL` FSM, shared argument binder, CPython call shapes |

## Build

```bash
cd docs/paper/systems
pdflatex architecture_overview.tex
pdflatex architecture_overview.tex   # TOC
pdflatex call_fsm.tex
pdflatex call_fsm.tex
```

Needs a TeX distribution with `tikz`, `booktabs`, `hyperref`, `listings`,
`geometry`, `microtype`.

## Conventions

- One subsystem per `.tex` file under `systems/` (or a future `excore/`, etc.).
- Prefer diagrams that match RTL names (`call_phase_r`, binder subs) so the note
  stays a faithful companion to the code.
- Link the living opcode matrix (`pycore/docs/bytecode_support.md`) rather than
  duplicating support status that churns weekly.
- Start from `architecture_overview.tex` for the paper outline; deepen individual
  components into sibling notes as they stabilize.
