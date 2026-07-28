# mm_test.s — standalone harness exercising mm_alloc / mm_free.
# Assembled as: cat mm_test.s mm.s  (mm.s provides allocator; this file
# provides MMIO equates, sp_read/write, and a scripted test main).

    .equ MMIO_BASE,      0xF0000000
    .equ MB_STATUS,      0x00
    .equ MB_HEAP_PTR,    0x14
    .equ RES_CODE,       0x80
    .equ RES_POP_COUNT,  0x84
    .equ RES_PUSH_COUNT, 0x88
    .equ RES_HEAP_PTR,   0x8C
    .equ RES_GO,         0xC0
    .equ SP_ADDR,        0xD0
    .equ SP_CTRL,        0xD4
    .equ SP_STATUS,      0xD8
    .equ SP_DATA0,       0xE0
    .equ SP_DATA1,       0xE4
    .equ SP_DATA2,       0xE8
    .equ SP_DATA3,       0xEC
    .equ SP_CTRL_READ,   1
    .equ SP_CTRL_WRITE,  2
    .equ SP_STATUS_BUSY, 1
    .equ SP_STATUS_FAULT,2
    .equ RES_COMPLETED,  0
    .equ RES_FATAL,      2
    .equ FATAL_MEM_FAULT,7
    .equ HEAP_LIMIT,     0x2000
    .equ SCRATCH_TOP,    0x400
    .equ SCR_A0,         0x58
    .equ SCR_A1,         0x5C
    # Result scratch in dmem for TB to peek:
    .equ OUT_STATUS,     0x0400
    .equ OUT_PTR0,       0x0410
    .equ OUT_PTR1,       0x0420
    .equ OUT_REUSE,      0x0430
    .equ OUT_OOM,        0x0440

reset:
    li   s11, MMIO_BASE
    li   sp, SCRATCH_TOP

wait_trap:
    lw   t0, MB_STATUS(s11)
    andi t0, t0, 1
    beq  t0, x0, wait_trap
    li   sp, SCRATCH_TOP
    j    run_tests

fatal_mem:
    li   t0, FATAL_MEM_FAULT
    slli t0, t0, 4
    ori  t0, t0, RES_FATAL
    sw   t0, RES_CODE(s11)
    sw   x0, RES_POP_COUNT(s11)
    sw   x0, RES_PUSH_COUNT(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

sp_read:
    sw   a0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
sp_read_poll:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, sp_read_poll
    andi t1, t0, SP_STATUS_FAULT
    beq  t1, x0, sp_read_ok
    j    fatal_mem
sp_read_ok:
    jalr x0, ra, 0

sp_write:
    sw   a0, SP_ADDR(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
sp_write_poll:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, sp_write_poll
    jalr x0, ra, 0

# Scripted tests; any failure → store nonzero at OUT_STATUS and complete.
run_tests:
    li   t0, 0
    sw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   a0, OUT_STATUS
    jal  ra, sp_write

    # 1) alloc 64 → ok
    li   a0, 64
    li   a1, 0
    li   a2, 0
    jal  ra, mm_alloc
    bne  a0, x0, fail1
    sw   a2, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, OUT_PTR0
    jal  ra, sp_write
    mv   s0, a2

    # 2) alloc 64 again
    li   a0, 64
    li   a1, 0
    li   a2, 0
    jal  ra, mm_alloc
    bne  a0, x0, fail2
    sw   a2, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, OUT_PTR1
    jal  ra, sp_write
    mv   s1, a2
    beq  s0, s1, fail2b

    # 3) free first, alloc 64 → should reuse s0
    mv   a0, s0
    jal  ra, mm_free
    li   a0, 64
    li   a1, 0
    li   a2, 0
    jal  ra, mm_alloc
    bne  a0, x0, fail3
    sw   a2, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, OUT_REUSE
    jal  ra, sp_write
    bne  a2, s0, fail3b

    # 4) OOM: request larger than remaining heap
    li   a0, 0x3000
    li   a1, 0
    li   a2, 0
    jal  ra, mm_alloc
    beq  a0, x0, fail4
    sw   a0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, OUT_OOM
    jal  ra, sp_write

    # success
    li   t0, 0
    sw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   a0, OUT_STATUS
    jal  ra, sp_write
    j    done_ok

fail1:
    li   t0, 1
    j    fail_store
fail2:
    li   t0, 2
    j    fail_store
fail2b:
    li   t0, 22
    j    fail_store
fail3:
    li   t0, 3
    j    fail_store
fail3b:
    li   t0, 33
    j    fail_store
fail4:
    li   t0, 4
fail_store:
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, OUT_STATUS
    jal  ra, sp_write

done_ok:
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    sw   x0, RES_POP_COUNT(s11)
    sw   x0, RES_PUSH_COUNT(s11)
    jal  ra, mm_store_res_heap
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap
