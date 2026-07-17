# excore MMIO map

Implemented in `excore/rtl/excore_mmio.sv`. All registers are 32-bit,
word-aligned, accessed via `LW`/`SW` at `0xF000_0000 + offset` from
`excore_cpu`. Offsets below are the low byte of the address
(`excore_mmio` decodes `cpu_addr_i[7:0]`).

## Mailbox (read side — populated by the pycore trap message)

Read-only from the CPU. In Phase B a testbench drives these directly with
canned trap messages; in Phase C `trap_mailbox.sv` / `pycore_system` drive
them on a real `trap_req` handshake (see `architecture.md`).

| Offset | Name | Fields |
| --- | --- | --- |
| `0x00` | `MB_STATUS` | bit0 `trap_pending` (RO), bit1 `result_accepted` (RO) |
| `0x04` | `MB_TRAP_CODE` | `[3:0]` |
| `0x08` | `MB_PC` | trapping pc (slot index) |
| `0x0C` | `MB_INSTR_LO` | `{arg[23:0], opcode[7:0]}` |
| `0x10` | `MB_INSTR_HI` | `{24'd0, arg[31:24]}` |
| `0x14` | `MB_HEAP_PTR` | |
| `0x18` | `MB_ENTRY_COUNT` | `[2:0]` |
| `0x20..` | `MB_ENTRY[i]` | `i = 0..MAX_TRAP_ENTRIES-1` (default 3), 5 words each: `VAL0..VAL3` (LSW first), `TAG`. Stride 0x14 (20 bytes). |

`result_accepted` is set the cycle `RES_GO` commits and clears whenever
`trap_pending` is not asserted (a fresh trap starts from a clean status).

## Result (write side)

Written by firmware; consumed externally (testbench in Phase B,
`trap_res` handshake in Phase C).

| Offset | Name | Fields |
| --- | --- | --- |
| `0x80` | `RES_CODE` | `[3:0]` code: 0=COMPLETED, 1=RETRY, 2=FATAL; `[7:4]` `fatal_code` (meaningful only when code=FATAL) |
| `0x84` | `RES_POP_COUNT` | `[2:0]` |
| `0x88` | `RES_PUSH_COUNT` | `[1:0]` |
| `0x8C` | `RES_HEAP_PTR` | |
| `0x90..` | `RES_ENTRY[i]` | `i = 0..MAX_RES_ENTRIES-1` (default 2), 5 words each (pushed entries, bottom first). Stride 0x14. |
| `0xC0` | `RES_GO` | write bit0=1: latch the result (pulses one-cycle `res_go_o`), mark `result_accepted`, park (firmware jumps to its own dispatch-loop top; there is no hardware "clear trap_pending" side effect inside excore_mmio itself — that is the mailbox owner's job once it consumes the result). |

## Shared-dmem slot port

Bridges the 32-bit hart to 128-bit pycore dmem slots (`pycore_mem_bank` is
untouched — this is purely an address/data-width adapter). One transaction
in flight at a time; `SP_CTRL` bit0/bit1 are one-shot strobes, not held
state.

| Offset | Name | Fields |
| --- | --- | --- |
| `0xD0` | `SP_ADDR` | byte address, 16-aligned (matches a pycore dmem slot) |
| `0xD4` | `SP_CTRL` | bit0 `read_go`, bit1 `write_go` (write-strobe; not stored) |
| `0xD8` | `SP_STATUS` | bit0 `busy` (RO), bit1 `fault` (RO, sticky until the next go) |
| `0xE0..0xEC` | `SP_DATA0..3` | 128-bit slot data window, LSW first (`SP_DATA0` = bits `[31:0]`, … `SP_DATA3` = bits `[127:96]`) |

Firmware sequence for a slot read: write `SP_ADDR`, write `SP_CTRL` with
bit0 set, poll `SP_STATUS.busy` until clear, check `SP_STATUS.fault`, read
`SP_DATA0..3`. A write is the same sequence with `SP_DATA0..3` written
*before* `SP_CTRL` bit1, and no `SP_DATA` read afterward.

## Message field widths (parameterized for future handlers)

`MAX_TRAP_ENTRIES = 3`, `MAX_RES_ENTRIES = 2` — both are `excore_mmio`
module parameters so a later trap handler that needs more operands widens
them in one place (and in the mirrored `trap_mailbox.sv` bus widths, Phase
C).
