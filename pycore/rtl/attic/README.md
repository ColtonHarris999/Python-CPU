# Attic — unintegrated design studies

These modules are **not** part of the built PyCore RTL (`PYCORE_RTL_SRCS`) and
are not instantiated anywhere in the current design:

- `pycore_frame_buffer.sv` — ring-buffer / spill frame design study
- `pycore_const_table.sv` — fixed constant-ROM study (superseded by inline
  `LOAD_CONST` encoding in the instruction stream)

They are retained here as reference material for possible future work. Do not
treat them as the source of truth for runtime behavior; see
`pycore/docs/architecture.md` for the as-built `pycore_frame.sv` description.
