# CPython research benchmarks across machines

Cold-exec time for the research set. PyCore is the measured hart. Every other series is CPython 3.14 under the simple-core model (`cpython_baseline`) at that preset's own clock, so a faster clock is part of the machine. The same cycle counts are in the table.

Regenerate with `make research-compare-machines`.

Recorded 2026-10-13 20:48 UTC.

![Research cold-exec time](research_machines.svg)

## Geometric mean

| machine | clock | programs | geomean cycles | geomean time |
| --- | ---: | ---: | ---: | ---: |
| PyCore hart 1 GHz | 1000 MHz | 10 | 161,542,937 | 161.54 ms |
| CPython, Romer 100 MHz | 100 MHz | 10 | 670,283,385 | 6.703 s |
| CPython, PyCore caches 100 MHz | 100 MHz | 10 | 625,886,479 | 6.259 s |
| CPython, gem5 classic 1 GHz | 1000 MHz | 10 | 617,002,689 | 617.00 ms |
| CPython, Skylake 3.4 GHz | 3400 MHz | 10 | 565,447,798 | 166.31 ms |

## Cold exec, per program

| program | PyCore hart 1 GHz | CPython, Romer 100 MHz | CPython, PyCore caches 100 MHz | CPython, gem5 classic 1 GHz | CPython, Skylake 3.4 GHz |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | 57.60 ms (57,602,026) | 2.412 s (241,243,164) | 2.144 s (214,397,844) | 217.93 ms (217,926,622) | 62.36 ms (212,019,401) |
| fannkuch.py | 426.50 ms (426,496,378) | 6.973 s (697,285,444) | 7.319 s (731,894,191) | 792.12 ms (792,120,948) | 215.30 ms (732,035,212) |
| fasta.py | 9.76 ms (9,760,590) | 510.52 ms (51,052,371) | 492.35 ms (49,235,485) | 47.44 ms (47,444,251) | 12.41 ms (42,210,409) |
| knucleotide.py | 207.84 ms (207,840,854) | 7.426 s (742,634,844) | 6.717 s (671,655,038) | 661.15 ms (661,147,955) | 176.61 ms (600,483,755) |
| mandelbrot.py | 438.20 ms (438,200,030) | 28.468 s (2,846,821,457) | 25.051 s (2,505,121,348) | 2.197 s (2,197,133,819) | 561.76 ms (1,909,969,068) |
| monte_carlo.py | 190.49 ms (190,494,990) | 12.499 s (1,249,894,713) | 12.171 s (1,217,119,936) | 1.166 s (1,165,878,357) | 281.53 ms (957,214,388) |
| nbody.py | 430.19 ms (430,185,572) | 23.794 s (2,379,406,237) | 21.291 s (2,129,092,433) | 2.073 s (2,072,767,969) | 572.20 ms (1,945,478,172) |
| nqueens.py | 176.05 ms (176,053,066) | 4.056 s (405,645,563) | 4.033 s (403,342,416) | 407.07 ms (407,066,833) | 116.77 ms (397,014,835) |
| sor.py | 115.47 ms (115,473,570) | 3.313 s (331,258,013) | 2.900 s (289,982,055) | 310.51 ms (310,513,294) | 85.29 ms (289,984,059) |
| spectral_norm.py | 332.65 ms (332,645,506) | 25.230 s (2,522,971,283) | 23.413 s (2,341,320,173) | 2.200 s (2,200,291,245) | 610.06 ms (2,074,216,079) |

Each cell is simulated time at that machine's clock, then the cycle count.
Time is cycles / clock. A smaller bar is a faster machine.
