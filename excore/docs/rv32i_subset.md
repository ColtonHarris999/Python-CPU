# excore supported RV32I subset

`excore_cpu.sv` implements exactly the following RV32I instructions.
Anything else — any other opcode, or a reserved `funct3`/`funct7`
combination within a supported opcode — raises `fault_o` (sticky; the core
parks permanently) as a hardware correctness backstop. Firmware never emits
anything outside this subset; `fault_o` should never assert for correct
firmware.

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

Explicitly **not** supported:

- `LB`/`LH`/`LBU`/`LHU`/`SB`/`SH` — all data accesses are word-aligned;
  `LW`/`SW` to a misaligned address (`addr[1:0] != 0`) also raises
  `fault_o`.
- CSRs, `FENCE`, `ECALL`, `EBREAK` — no privileged/system state. "Halt" or
  "park" is a firmware jump-to-self (an infinite loop at the dispatch
  loop's top, waiting for the next `MB_STATUS.trap_pending`), not a
  hardware halt state.
- `MUL`/`DIV`/`REM` (M extension), compressed instructions (`C` extension),
  floating point (`F`/`D`) — out of scope; not needed for a firmware
  dispatch loop doing address arithmetic and MMIO polling.

## Memory model

Harvard split: instruction fetch never touches the data bus.

- **Instructions**: a private 4 KB instruction array (`FW_HEX` parameter,
  `$readmemh`), addressed by `pc[11:2]` (1024 32-bit words). Not
  externally visible or writable at runtime.
- **Data**: a single 32-bit address space, decoded by `excore_cpu` itself:
  - `0x0000_0000` – `0x0000_03FF` (1 KB): private scratch RAM,
    word-addressed, completes in the same cycle as the access (no bus
    round trip — it's a tiny local array, not a real SRAM macro).
  - `0xF000_0000` and up: routed to the external MMIO bus master port
    (`mmio_req_o`/`mmio_we_o`/`mmio_addr_o`/`mmio_wdata_o` ->
    `mmio_ack_i`/`mmio_rdata_i`), which `excore_mmio.sv` answers — see
    `mmio_map.md`. One transaction in flight at a time; a genuine
    single-cycle request pulse (mirrors `pycore_mem_stage`'s
    `req_sent_r` discipline) so `pycore_mem_bank`-style slaves that ack
    unconditionally one cycle after every sampled request never see a
    duplicate transaction.
  - Anything else (including the gap between scratch RAM and the MMIO
    base): out-of-range, raises `fault_o`.

## FSM

Multi-cycle, no pipeline (this core's job is correctness and small area,
not throughput — see `architecture.md`'s excore section for the
rationale). Every instruction costs 2 cycles (`S_FETCH`, `S_EXEC`) except a
load/store that targets the MMIO bus, which costs a 3rd cycle (`S_MEM`)
waiting for the bus ack.
