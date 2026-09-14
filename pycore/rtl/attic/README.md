# Attic — unintegrated design studies

Modules here are **not** part of the built PyCore RTL (`PYCORE_RTL_SRCS`) and
are not instantiated in the current design.

- `pycore_frame_buffer.sv` — ring-buffer / spill frame design study.
  **Superseded by [`planning/compiler_design.md`](../../../planning/compiler_design.md)
  §6.1** (one watermark, not per-slot residency). Retained as negative
  prior art; do not instantiate.

See `pycore/docs/architecture.md` for the as-built `pycore_frame.sv`
push/pop call-stack description (the production path today).
