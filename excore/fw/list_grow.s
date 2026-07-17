# list_grow.s -- excore firmware: the LIST_GROW trap handler.
#
# Dispatch loop, parked until MB_STATUS.trap_pending is set. Currently
# handles exactly one trap code (PY_TRAP_LIST_GROW = 9); any other code is
# an unrecoverable firmware bug (should never happen -- pycore only ever
# marshals recoverable trap codes to the excore) and reports
# FATAL(ILLEGAL_OPCODE).
#
# LIST_GROW protocol (see excore/docs/mmio_map.md and pycore_defs.svh's
# LIST layout v2 comments):
#   ENTRY[0] = list handle (tag must be PY_TAG_LIST; value[31:0] = obj_addr)
#   ENTRY[1] = the element being appended (full 128-bit value + tag)
#
# Algorithm:
#   1. Tag-check ENTRY[0] == LIST, else FATAL(TYPE).
#   2. Slot-read the object header at obj_addr -> {cap, len}.
#   3. Slot-read ob_item at obj_addr+16 -> old_buf.
#   4. new_cap = cap ? cap*2 : 4 (covers the size-0 list case).
#      new_buf = MB_HEAP_PTR. OOM if new_buf + new_cap*32 > HEAP_LIMIT.
#   5. Copy `len` elements (2 slots each: value + tag) old_buf -> new_buf.
#      A cap-0 list has len=0 and old_buf=0 -- the loop below is naturally
#      skipped (i == len immediately), so no slot-port read is ever issued
#      for that case.
#   6. Append ENTRY[1] at new_buf + len*32 (value slot + tag slot).
#   7. Write back the header {new_cap, len+1} and ob_item = new_buf.
#   8. RES: COMPLETED, pop 1 (the appended element), push 0,
#      RES_HEAP_PTR = new_buf + new_cap*32. GO; park (loop back to the
#      dispatch top and wait for the next trap_pending).
#
# The old buffer is INTENTIONALLY LEAKED here -- this is a bump allocator
# with no free list, matching pycore's own heap allocator discipline. This
# is exactly the motivating case for the future GC milestone: every list
# grow leaks its previous buffer, and nothing in this design reclaims it.

    .equ MMIO_BASE,      0xF0000000

    .equ MB_STATUS,      0x00
    .equ MB_TRAP_CODE,   0x04
    .equ MB_HEAP_PTR,    0x14
    .equ MB_E0_VAL0,     0x20
    .equ MB_E0_TAG,      0x30
    .equ MB_E1_VAL0,     0x34
    .equ MB_E1_VAL1,     0x38
    .equ MB_E1_VAL2,     0x3C
    .equ MB_E1_VAL3,     0x40
    .equ MB_E1_TAG,      0x44

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

    .equ TRAP_LIST_GROW, 9

    # fatal_code values mirror pycore_defs.svh's PY_TRAP_* codes exactly --
    # Phase C forwards this nibble straight into pycore_trap as a normal
    # halt (see architecture.md's trap taxonomy).
    .equ FATAL_TYPE,           1
    .equ FATAL_ILLEGAL_OPCODE, 5
    .equ FATAL_MEM_FAULT,      7

    .equ TAG_LIST,       10
    .equ HEAP_LIMIT,     0x2000

reset:
    li   s11, MMIO_BASE            # s11: persistent MMIO base, never clobbered

wait_trap:
    lw   t0, MB_STATUS(s11)
    andi t0, t0, 1
    beq  t0, x0, wait_trap

    lw   t0, MB_TRAP_CODE(s11)
    li   t1, TRAP_LIST_GROW
    beq  t0, t1, do_list_grow
    j    fatal_illegal

do_list_grow:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_LIST
    bne  t0, t1, fatal_type

    lw   s0, MB_E0_VAL0(s11)       # s0 = obj_addr

    # ---- slot-read header at obj_addr -> len (s2), cap (s1) ------------
    sw   s0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_hdr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_hdr
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s2, SP_DATA0(s11)         # s2 = len
    lw   s1, SP_DATA2(s11)         # s1 = cap

    # ---- slot-read ob_item at obj_addr+16 -> old_buf (s5) ---------------
    addi t0, s0, 16
    sw   t0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_obitem:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_obitem
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s5, SP_DATA0(s11)         # s5 = old_buf (ob_item)

    # ---- new_cap = cap ? cap*2 : 4 (s3) ---------------------------------
    beq  s1, x0, cap_zero
    slli s3, s1, 1
    j    cap_done
cap_zero:
    li   s3, 4
cap_done:

    lw   s4, MB_HEAP_PTR(s11)      # s4 = new_buf

    # ---- OOM check: new_buf + new_cap*32 > HEAP_LIMIT -> FATAL(MEM_FAULT)
    slli t0, s3, 5
    add  t0, s4, t0                # t0 = new_buf + new_cap*32
    li   t1, HEAP_LIMIT
    bge  t1, t0, copy_start        # HEAP_LIMIT >= t0  =>  fits, proceed
    j    fatal_mem

    # ---- copy `len` elements old_buf -> new_buf (s6 = index i) ----------
copy_start:
    li   s6, 0
copy_loop:
    beq  s6, s2, copy_done

    slli t0, s6, 5                 # t0 = i*32
    add  t2, s5, t0                # t2 = old value-slot addr
    add  t3, s4, t0                # t3 = new value-slot addr

    # value slot (128 bits): read old, write new.
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_copy_val_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_copy_val_rd
    lw   t4, SP_DATA0(s11)
    lw   t5, SP_DATA1(s11)
    lw   t6, SP_DATA2(s11)
    lw   a0, SP_DATA3(s11)

    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    sw   t5, SP_DATA1(s11)
    sw   t6, SP_DATA2(s11)
    sw   a0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_copy_val_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_copy_val_wr

    # tag slot (32 bits, upper 124 bits always zero): read old, write new.
    addi t2, t2, 16
    addi t3, t3, 16
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_copy_tag_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_copy_tag_rd
    lw   t4, SP_DATA0(s11)

    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_copy_tag_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_copy_tag_wr

    addi s6, s6, 1
    j    copy_loop

    # ---- append ENTRY[1] at new_buf + len*32 -----------------------------
copy_done:
    slli t0, s2, 5
    add  t3, s4, t0                 # t3 = new element value-slot addr

    lw   t4, MB_E1_VAL0(s11)
    lw   t5, MB_E1_VAL1(s11)
    lw   t6, MB_E1_VAL2(s11)
    lw   a0, MB_E1_VAL3(s11)

    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    sw   t5, SP_DATA1(s11)
    sw   t6, SP_DATA2(s11)
    sw   a0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_append_val:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_append_val

    addi t3, t3, 16
    lw   t4, MB_E1_TAG(s11)
    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_append_tag:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_append_tag

    # ---- write back header {new_cap, len+1} at obj_addr ------------------
    addi t4, s2, 1                  # new_len = len + 1
    sw   s0, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s3, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_hdr_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_hdr_wb

    # ---- write ob_item = new_buf at obj_addr+16 --------------------------
    addi t2, s0, 16
    sw   t2, SP_ADDR(s11)
    sw   s4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_obitem_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_obitem_wb

    # ---- RES: COMPLETED, pop 1, push 0 -----------------------------------
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    slli t0, s3, 5
    add  t0, s4, t0                 # new_buf + new_cap*32
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

fatal_type:
    li   t0, FATAL_TYPE
    j    do_fatal

fatal_illegal:
    li   t0, FATAL_ILLEGAL_OPCODE
    j    do_fatal

fatal_mem:
    li   t0, FATAL_MEM_FAULT
    j    do_fatal

do_fatal:
    slli t0, t0, 4
    ori  t0, t0, RES_FATAL
    sw   t0, RES_CODE(s11)
    li   t0, 0
    sw   t0, RES_POP_COUNT(s11)
    sw   t0, RES_PUSH_COUNT(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap
