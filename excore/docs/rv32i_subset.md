# excore RISC-V hart (vendored singlecore multicycle)

The excore execution engine is the **5-stage multicycle RV32** hart from
`singlecore.zip` (`excore/rtl/singlecore/riscv_multicycle.sv`), wrapped by
`excore_cpu.sv`. The wrapper preserves the excore memory map and MMIO
contract used by `list_grow.s` / `excore_mmio.sv`.

Firmware is assembled for the RV32I subset below (what `asm_rv32.py` emits).
The vendored hart understands a broader RV32 encoding surface (including
paths for AMO / M-extension decode helpers), but excore firmware only ever
emits the instructions listed here.

| Class | Instructions |
| --- | --- |
| U-type | `LUI`, `AUIPC` |
| J-type | `JAL` |
| I-type (jump) | `JALR` |
| B-type | `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU` |
| I-type (load) | `LW` |
| S-type (store) | `SW` |
| I-type (arithmetic) | `ADDI`, `ANDI`, `ORI`, `XORI`, `SLTI`, `SLTIU` |
| I-type (shift) | `SLLI`, `SRLI`, `SRAI` |
| R-type | `ADD`, `SUB`, `AND`, `OR`, `XOR`, `SLT`, `SLTU`, `SLL`, `SRL`, `SRA` |

Excore firmware does **not** use:

- `LB`/`LH`/`LBU`/`LHU`/`SB`/`SH` — all firmware data accesses are
  word-aligned `LW`/`SW`.
- CSRs, `FENCE`, `ECALL`, `EBREAK` — park is a firmware jump-to-self on
  `MB_STATUS.trap_pending`.
- `MUL`/`DIV`/`REM`, compressed (`C`), floating point (`F`/`D`).

## Memory model (wrapper)

Harvard split: instruction fetch never touches the data bus. Implemented
in `excore_cpu.sv` as slaves on the hart's `memory_io_*` ports:

- **Instructions**: private IMEM word array (`FW_HEX` / `$readmemh`,
  default 8 KB / 2048 words), addressed by PC. Not writable at runtime.
- **Data**:
  - `0x0000_0000` – `0x0000_03FF` (1 KB): private scratch RAM
  - `0xF000_0000` and up: external MMIO master port → `excore_mmio`
  - anything else: sticky `fault_o` (and a dummy response so the hart
    cannot hang)

Both instruction and data responses use the registered one-cycle
`memory_io` timing of the original singlecore `memory32` module so the
multicycle stage machine (`fetch → decode → execute → mem → writeback`)
advances correctly. MMIO requests are one-cycle pulses into `excore_mmio`
(same as before).

## FSM (vendored hart)

Five stages in `riscv_multicycle.sv`: `stage_fetch`, `stage_decode`,
`stage_execute`, `stage_mem`, `stage_writeback`. Memory ops wait in
writeback until `data_mem_rsp.valid`. See `excore/rtl/singlecore/README.md`
for the vendored file list.
