# mpycore memory map

v1 locks from [`planning/micropython_mcu_plan.md`](../../planning/micropython_mcu_plan.md).
Addresses follow the Cortex-M split: code low, SRAM at `0x2000_0000`,
peripherals at `0x4000_0000`. A smaller SRAM is a later parameter, after a
program has run at 256 KB.

| Window | Base | Size | Contents |
| --- | --- | ---: | --- |
| Flash | `0x0000_0000` | 512 KB | frozen `.mpy`, qstr pool, builtin bytecode |
| SRAM | `0x2000_0000` | 256 KB | GC heap, value stack, exception stack |
| MMIO | `0x4000_0000` | 4 KB | UART TX/RX, GPIO, timer, IRQ pending and enable |
| Sim control | `0xE000_0000` | 256 B | halt reason, cycle counter. Simulation only |

SRAM is 1-cycle. Flash has a wait-state parameter defaulting to 1 in
simulation. There is no L2 and no 16 MB backing RAM in the programming
model.

## Peripheral registers

Word offsets from `0x4000_0000`. Later phases may add registers. These
five stay put.

| Offset | Name | Access |
| --- | --- | --- |
| `0x00` | `UART_TX` | write `[7:0]`; the simulator prints the byte |
| `0x04` | `UART_RX` | read `[7:0]`; bit 31 is data-valid |
| `0x08` | `GPIO_OUT` | write the output word |
| `0x0C` | `TIMER_COUNT` | read free-running counter; write reloads the compare |
| `0x10` | `IRQ_STATUS` | read pending, write-1-to-clear |
| `0x14` | `IRQ_ENABLE` | read/write mask. Bit 0 timer, bit 1 UART RX |

`CONSOLE_TX` at `0xF0` belongs to the CPython hart. This UART is a
different register on a different map.

The host tool `mpycore/tools/mpy_image.py` packs a frozen `.mpy` into the
flash image the hart will execute in place: qstr pool, immediate const
words, and raw bytecode including preludes.
