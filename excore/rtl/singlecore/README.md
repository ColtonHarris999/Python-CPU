# Vendored singlecore RISC-V hart

Source: `singlecore.zip` on the `excore` branch (the course / reference
RISC-V CPU previously referenced by the empty `singlecore/` gitlink).
Vendored under `excore/rtl/singlecore/` so the multicycle hart lives next
to the MMIO / mailbox glue.

The excore uses the **5-stage multicycle** hart (`riscv_multicycle.sv`) as
its execution engine. Wrapping, private IMEM preload, scratch RAM, and the
MMIO bridge to `excore_mmio` live in `../excore_cpu.sv`.

Files kept here are the minimum needed to elaborate `riscv_multicycle` for
RV32 (no caches, no FGMT/pipelined variants, no 64-bit path):

| File | Role |
| --- | --- |
| `system.sv` | Word-size / address-size macros (`__32bit__`) |
| `base.sv` / `vivado.sv` | `bool`/`true`/`false` and synth attributes |
| `memory_io.sv` | `memory_io_req` / `memory_io_rsp` bus structs |
| `riscv.sv` + `riscv32_common.sv` | Decode / execute helpers (package `riscv`) |
| `riscv_multicycle.sv` | 5-stage multicycle RV32 core |

Do not edit these files lightly — prefer adapting the wrapper in
`excore_cpu.sv` so upstream singlecore fixes can be re-vendored cleanly.
