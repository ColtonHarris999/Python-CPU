# PyCore documentation

| Document | Description |
| --- | --- |
| [`pycore_execution_flow.pdf`](pycore_execution_flow.pdf) | **Execution flow specification** (diagram-heavy LaTeX). Source: [`pycore_execution_flow.tex`](pycore_execution_flow.tex) |
| [`architecture.md`](architecture.md) | Architecture overview (tags, FSM, memory, containers) |
| [`preprocessing_breakdown.md`](preprocessing_breakdown.md) | Image-builder fidelity rules and host/on-core budget |
| [`bytecode_support.md`](bytecode_support.md) | CPython 3.14 opcode support matrix |

## Build the specification PDF

From the repository root (requires `pdflatex` / TeX Live):

```bash
make pycore-docs
```

Or manually:

```bash
cd pycore/docs
pdflatex pycore_execution_flow.tex
pdflatex pycore_execution_flow.tex
```
