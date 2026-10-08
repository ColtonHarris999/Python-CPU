# excore_min — reset, FW_CAPS, and a jump-table stub.
# No container, string, or console code. Any trap is FATAL(ILLEGAL_OPCODE)
# until P7 fills in EMULATE handlers.
    .equ MMIO_BASE,      0xF0000000
    .equ MB_STATUS,      0x00
    .equ RES_CODE,       0x80
    .equ RES_GO,         0xC0
    .equ FW_CAPS,        0x100
    .equ FW_CAPS_VALID,  0x104
    # variant 1, ABI 1, EMULATE only.
    .equ FW_CAPS_MIN,    0x00010001
    .equ RES_FATAL_ILL,  0x52          # code=FATAL(2), fatal_code=ILLEGAL(5)

reset:
    li   s11, MMIO_BASE
    li   t0, FW_CAPS_MIN
    sw   t0, FW_CAPS(s11)
    li   t0, 1
    sw   t0, FW_CAPS_VALID(s11)

wait_trap:
    lw   t0, MB_STATUS(s11)
    andi t0, t0, 1
    beq  t0, x0, wait_trap
    li   t0, RES_FATAL_ILL
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap
