# Attic — unintegrated design studies

Modules here are **not** part of the built PyCore RTL (`PYCORE_RTL_SRCS`) and
are not instantiated in the current design.

- `pycore_frame_buffer.sv` — ring-buffer / spill frame design study with a
  per-slot residency map. **Superseded** by the §6.1 suffix-watermark ring in
  `pycore_core.sv` / `pycore_regfile.sv` (`planning/compiler_design.md`).
  Retained so the rejected per-slot approach stays readable; do not instantiate.

`pycore_code_mem.sv` and `pycore_code_ram.sv` still live under `pycore/rtl/`
and are listed in `PYCORE_RTL_SRCS`, but **neither is instantiated**. The
live ROM/RAM split is inside `pycore_ram.sv` (`code_loading.md` §1).

See `pycore/docs/architecture.md` for the as-built RF ring and
`pycore_frame.sv` descriptor stack.
