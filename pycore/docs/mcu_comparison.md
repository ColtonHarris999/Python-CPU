# MCU benchmark comparison

The research kernels are compared with MicroPython, not with CPython.
The desktop CPython numbers stay in `research_comparison.md`.

Recorded 2026-10-15T10:59:56Z.
Oracle: MicroPython `/usr/bin/micropython` (3.4.0; MicroPython v1.25.0+ds-1 on 2025-05-04).

MicroPython unix time is host wall time. It checks the checksum.
It is not a microcontroller clock. PyCore time is hart exec cycles
at the 1 GHz column of the last research comparison.

## PyCore hart and MicroPython unix

| program | result | checksum | PyCore exec | PyCore @ 1 GHz | MicroPython unix |
| --- | --- | --- | ---: | ---: | ---: |
| binary_trees.py | PASS | `135854` | 57,602,026 | 57.60 ms | 0.022 s |
| fannkuch.py | PASS | `22` | 426,496,378 | 426.50 ms | 0.050 s |
| fasta.py | PASS | `961628` | 9,760,590 | 9.76 ms | 0.005 s |
| knucleotide.py | PASS | `916380849` | 207,840,854 | 207.84 ms | 0.069 s |
| mandelbrot.py | PASS | `15899` | 438,200,030 | 438.20 ms | 0.158 s |
| monte_carlo.py | PASS | `3135320` | 190,494,990 | 190.49 ms | 0.062 s |
| nbody.py | PASS | `-169075163 -169089262` | 430,185,572 | 430.19 ms | 0.221 s |
| nqueens.py | PASS | `92` | 176,053,066 | 176.05 ms | 0.028 s |
| sor.py | PASS | `475119604` | 115,473,570 | 115.47 ms | 0.036 s |
| spectral_norm.py | PASS | `1274222209` | 332,645,506 | 332.65 ms | 0.143 s |

## Similar MCUs

Each board is a 32-bit microcontroller with on-chip SRAM of a few
hundred kilobytes, and each one can run the same program in C, C++,
and MicroPython. A cell is filled from
`pycore/tools/mcu_bench/peers/*.json`. This run does not flash a board.

| board | cpu | clock | SRAM | flash | C | C++ | MicroPython |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| Raspberry Pi Pico (RP2040) | Cortex-M0+ | 133 MHz | 264 KB | 2048 KB | not measured | not measured | not measured |
| STM32F411 | Cortex-M4F | 100 MHz | 128 KB | 512 KB | not measured | not measured | not measured |
| nRF52840 | Cortex-M4F | 64 MHz | 256 KB | 1024 KB | not measured | not measured | not measured |

Per program, when a board measurement exists:

No board measurement is checked in yet.

Board notes:

- **Raspberry Pi Pico (RP2040).** Official MicroPython port. C and C++ are the Pico SDK.
- **STM32F411.** MicroPython stm32 port. C and C++ are the STM32 HAL.
- **nRF52840.** 256 KB RAM, the same order as a small on-chip SRAM. C and C++ via Zephyr or the nRF SDK.
