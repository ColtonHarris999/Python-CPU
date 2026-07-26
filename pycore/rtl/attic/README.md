# Attic — unintegrated design studies

Modules here are **not** part of the built PyCore RTL (`PYCORE_RTL_SRCS`) and
are not instantiated in the current design.

- `pycore_frame_buffer.sv` — ring-buffer / spill frame design study. **Retained
  on purpose** for a possible future deep-call RF window; do not delete.

See `pycore/docs/architecture.md` for the as-built `pycore_frame.sv`
push/pop call-stack description (the production path today).
