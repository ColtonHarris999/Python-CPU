# Paper / systems documentation

Near-complete PyCore subsystems get a LaTeX note here so we can pull prose,
figures, and tradeoff tables into the research paper without mining RTL comments
or planning markdown.

## Layout

| Path | Topic |
| --- | --- |
| `systems/pycore_diagrams.tex` | Figure atlas: hart, register ring, memory system, accelerators |
| `systems/call_fsm.tex` | `S_CALL` FSM, shared argument binder, CPython call shapes |

`pycore_diagrams.tex` inputs one picture per file from `systems/figures/`.
Shared TikZ styles are `systems/figures/tikz_styles.tex`.
Copy a `tikzpicture` into the paper and keep that style file in the preamble.

## Build

```bash
cd docs/paper/systems
make
# or: pdflatex pycore_diagrams.tex && pdflatex pycore_diagrams.tex
```

Needs a TeX distribution with `tikz`, `booktabs`, `hyperref`, `listings`,
`geometry`, `microtype`.

## Conventions

- One subsystem per `.tex` file under `systems/` (or a future `excore/`, etc.).
- Prefer diagrams that match RTL names (`call_phase_r`, binder subs) so the note
  stays a faithful companion to the code.
- Link the living opcode matrix (`pycore/docs/bytecode_support.md`) rather than
  duplicating support status that churns weekly.
- Remaining work lives in `planning/master_plan.md`, not in these notes.
