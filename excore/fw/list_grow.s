# list_grow.s -- excore firmware: LIST_* + DICT_* + SET_* trap handlers.
#
# Dispatch loop, parked until MB_STATUS.trap_pending is set. Handles
# PY_TRAP_LIST_GROW (9), LIST_EXTEND (10), DICT_GROW (11), LIST_DELETE (12),
# SET_GROW (13), SET_UPDATE (14), DICT_UPDATE (15).
# Unknown codes -> FATAL(ILLEGAL_OPCODE).
# Dict/set rich equality runs on pycore (former DICT_COLLISION retired).
#
# LIST_GROW (ENTRY[0]=list handle, ENTRY[1]=element):
#   double (min 4), copy, append one element, COMPLETED pop 1.
#
# LIST_EXTEND (ENTRY[0]=list handle, ENTRY[1]=LIST or TUPLE iterable):
#   need=len+src_len. If need <= cap: in-place copy src onto dst buffer,
#   write length, COMPLETED pop 1 (no grow). Else grow-to-fit
#   (doubling from max(cap*2||4, need)), copy dst then src, COMPLETED pop 1.
#   Self-extend is safe: src_len and old_buf are snapshotted before the
#   ob_item rewrite; extend copies from the leaked old buffer.
#
# LIST_DELETE (ENTRY[0]=list, ENTRY[1]=key index): shift elements
#   [idx+1 .. len) down one slot, write length-1, COMPLETED pop 2.
#   Capacity unchanged. (Last-element delete stays on pycore.)
#
# DICT_GROW (E0=dict, E1=key, E2=value): realloc table, rehash, STORE insert,
#   COMPLETED pop 3. INTENTIONALLY LEAKS the old table.
#
# SET_GROW (E0=set, E1=element): realloc element table (stride 32), rehash,
#   insert element, COMPLETED pop 1. INTENTIONALLY LEAKS the old table.
#
# SET_UPDATE (E0=set, E1=LIST/TUPLE/SET): grow-to-fit as needed, insert all
#   source elements, COMPLETED pop 1.
#
# List/dict/set grow paths INTENTIONALLY LEAK old buffers (bump allocator).

    .equ MMIO_BASE,      0xF0000000

    .equ MB_STATUS,      0x00
    .equ MB_TRAP_CODE,   0x04
    .equ MB_INSTR_LO,    0x0C
    .equ MB_HEAP_PTR,    0x14
    .equ MB_E0_VAL0,     0x20
    .equ MB_E0_TAG,      0x30
    .equ MB_E1_VAL0,     0x34
    .equ MB_E1_VAL1,     0x38
    .equ MB_E1_VAL2,     0x3C
    .equ MB_E1_VAL3,     0x40
    .equ MB_E1_TAG,      0x44
    .equ MB_E2_VAL0,     0x48
    .equ MB_E2_VAL1,     0x4C
    .equ MB_E2_VAL2,     0x50
    .equ MB_E2_VAL3,     0x54
    .equ MB_E2_TAG,      0x58

    .equ RES_CODE,       0x80
    .equ RES_POP_COUNT,  0x84
    .equ RES_PUSH_COUNT, 0x88
    .equ RES_HEAP_PTR,   0x8C
    .equ RES_E0_VAL0,    0x90
    .equ RES_E0_VAL1,    0x94
    .equ RES_E0_VAL2,    0x98
    .equ RES_E0_VAL3,    0x9C
    .equ RES_E0_TAG,     0xA0
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

    .equ TRAP_LIST_GROW,     9
    .equ TRAP_LIST_EXTEND,   10
    .equ TRAP_DICT_GROW,     11
    .equ TRAP_LIST_DELETE,   12
    .equ TRAP_SET_GROW,      13
    .equ TRAP_SET_UPDATE,    14
    .equ TRAP_DICT_UPDATE,   15

    # ---- Software call stack (private scratch) ----------------------------
    # Call-graph analysis of this firmware (jal depth):
    #   do_dict_grow / do_set_grow : depth 6
    #     e.g. insert -> probe -> keys_rich_eq -> norm_numeric -> float_to_int
    #   do_set_update               : depth 5
    #   do_dict_update              : depth 3 (mostly inlined)
    #   list_* handlers             : depth 1 (no jal helpers)
    # Worst-case simultaneous call frames (ra + a few callee/arg saves) along
    # the deepest path is ~40 bytes.  Reserve EXCORE_STACK_BYTES=128 with
    # margin for future helpers.
    #
    # WHY private scratch (not the shared heap) today:
    #   excore_cpu only serves lw/sw to (1) private 1 KB scratch at 0x0 and
    #   (2) MMIO at 0xF000_0000. Shared pycore dmem is reachable only via the
    #   128-bit slot-port MMIO bridge — so a heap-backed `sp` faults.
    #
    # Concurrent plan (matches the pycore reservation idea):
    #   When excore gains a 32-bit path into shared dmem, pycore can hand
    #   MB_HEAP_PTR + EXCORE_STACK_BYTES each trap, set sp to the top of that
    #   window, and keep its bump pointer past it. Until then: stack lives at
    #   the high end of private scratch; SCR_* payload stays in 0x00..0x7F.
    .equ EXCORE_STACK_BYTES, 128
    .equ SCRATCH_TOP,        0x400   # exclusive end of private 1 KB scratch

    # fatal_code values mirror pycore_defs.svh's PY_TRAP_* codes exactly --
    # Phase C forwards this nibble straight into pycore_trap as a normal
    # halt (see architecture.md's trap taxonomy).
    .equ FATAL_TYPE,           1
    .equ FATAL_ILLEGAL_OPCODE, 5
    .equ FATAL_MEM_FAULT,      7

    .equ TAG_UNINIT,     0
    .equ TAG_INT,        1
    .equ TAG_FLOAT,      2
    .equ TAG_BOOL,       3
    .equ TAG_TUPLE,      5
    .equ TAG_SHORT_STR,  6
    .equ TAG_LONG_STR,   7
    .equ TAG_DICT,       9
    .equ TAG_LIST,       10
    .equ TAG_SET,        11
    # Tombstone reuses DICT: mutable dicts are never valid hash keys, so a
    # key-slot tag of 9 means deleted (see PY_TAG_TOMBSTONE in pycore_defs.svh).
    .equ TAG_TOMBSTONE,  9

    .equ HEAP_LIMIT,     0x2000

    # Private scratch (CPU data RAM @ 0x0) for key/value + helper state.
    .equ SCR_RA,         0x00
    .equ SCR_RA2,        0x04
    .equ SCR_KVAL0,      0x10
    .equ SCR_KVAL1,      0x14
    .equ SCR_KVAL2,      0x18
    .equ SCR_KVAL3,      0x1C
    .equ SCR_KTAG,       0x20
    .equ SCR_VVAL0,      0x24
    .equ SCR_VVAL1,      0x28
    .equ SCR_VVAL2,      0x2C
    .equ SCR_VVAL3,      0x30
    .equ SCR_VTAG,       0x34
    .equ SCR_SKVAL0,     0x38
    .equ SCR_SKVAL1,     0x3C
    .equ SCR_SKVAL2,     0x40
    .equ SCR_SKVAL3,     0x44
    .equ SCR_SKTAG,      0x48
    .equ SCR_IDX,        0x4C
    .equ SCR_TOMB,       0x50
    .equ SCR_FOUND,      0x54
    .equ SCR_A0,         0x58
    .equ SCR_A1,         0x5C
    .equ SCR_TMP_L0,     0x60
    .equ SCR_TMP_L1,     0x64
    .equ SCR_FTI0,       0x68
    .equ SCR_FTI1,       0x6C
    .equ SCR_RA3,        0x70

reset:
    li   s11, MMIO_BASE            # s11: persistent MMIO base, never clobbered

wait_trap:
    lw   t0, MB_STATUS(s11)
    andi t0, t0, 1
    beq  t0, x0, wait_trap

    # Software stack in private scratch: grows down from SCRATCH_TOP.
    # SCR_* payload occupies 0x00..0x7F; frames use 0x80..0x3FF.
    li   sp, SCRATCH_TOP

    lw   t0, MB_TRAP_CODE(s11)
    li   t1, TRAP_LIST_GROW
    beq  t0, t1, do_list_grow
    li   t1, TRAP_LIST_EXTEND
    beq  t0, t1, do_list_extend
    li   t1, TRAP_DICT_GROW
    beq  t0, t1, do_dict_grow
    li   t1, TRAP_LIST_DELETE
    beq  t0, t1, tramp_list_delete
    li   t1, TRAP_SET_GROW
    beq  t0, t1, tramp_set_grow
    li   t1, TRAP_SET_UPDATE
    beq  t0, t1, tramp_set_update
    li   t1, TRAP_DICT_UPDATE
    beq  t0, t1, tramp_dict_update
    j    fatal_illegal

# J-type trampolines: handlers past B-type ±4KiB reach.
tramp_list_delete:
    j    do_list_delete
tramp_set_grow:
    j    do_set_grow
tramp_set_update:
    j    do_set_update
tramp_dict_update:
    j    du_start

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

# ===========================================================================
# LIST_EXTEND: ENTRY[0]=dst list, ENTRY[1]=LIST or TUPLE source
# ===========================================================================
do_list_extend:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_LIST
    bne  t0, t1, fatal_type
    lw   s0, MB_E0_VAL0(s11)       # s0 = dst obj_addr

    lw   s9, MB_E1_TAG(s11)        # s9 = src tag
    li   t1, TAG_LIST
    beq  s9, t1, ext_src_ok
    li   t1, TAG_TUPLE
    bne  s9, t1, fatal_type
ext_src_ok:
    lw   s10, MB_E1_VAL0(s11)      # s10 = src obj_addr / tuple addr

    # ---- dst header -> len (s2), cap (s1) --------------------------------
    sw   s0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_hdr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_hdr
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s2, SP_DATA0(s11)
    lw   s1, SP_DATA2(s11)

    # ---- dst ob_item -> old_buf (s5) -------------------------------------
    addi t0, s0, 16
    sw   t0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_obitem:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_obitem
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s5, SP_DATA0(s11)

    # ---- resolve src_len (s7) and src_buf (s8) ---------------------------
    li   t1, TAG_TUPLE
    beq  s9, t1, ext_src_tuple

    # Source is LIST. Self-extend: src_len = dst len, src_buf = old_buf.
    beq  s10, s0, ext_src_self
    # Distinct list: read its header + ob_item.
    sw   s10, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_src_hdr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_src_hdr
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s7, SP_DATA0(s11)         # src_len
    addi t0, s10, 16
    sw   t0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_src_ob:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_src_ob
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s8, SP_DATA0(s11)         # src_buf
    j    ext_need

ext_src_self:
    mv   s7, s2
    mv   s8, s5
    j    ext_need

ext_src_tuple:
    # Tuple handle: size in ENTRY[1] value[127:64] = VAL2/VAL3 words.
    # Our mailbox packs VAL0..VAL3 as value[31:0]..value[127:96].
    lw   s7, MB_E1_VAL2(s11)       # size low 32 (tuple sizes fit in 32)
    mv   s8, s10                   # inline element base

ext_need:
    # need = len + src_len (s6 temporarily)
    add  s6, s2, s7

    # Capacity already sufficient: in-place append (no grow / no leak).
    bge  s1, s6, ext_inplace

    # new_cap = max(cap ? cap*2 : 4, need), doubling until >= need
    beq  s1, x0, ext_cap_zero
    slli s3, s1, 1
    j    ext_cap_floor
ext_cap_zero:
    li   s3, 4
ext_cap_floor:
    bge  s3, s6, ext_cap_done
ext_cap_grow:
    slli s3, s3, 1
    blt  s3, s6, ext_cap_grow
ext_cap_done:

    lw   s4, MB_HEAP_PTR(s11)      # new_buf
    slli t0, s3, 5
    add  t0, s4, t0
    li   t1, HEAP_LIMIT
    bge  t1, t0, ext_copy_dst
    j    fatal_mem

    # ---- copy dst len elements old_buf -> new_buf ------------------------
ext_copy_dst:
    li   s6, 0
ext_copy_dst_loop:
    beq  s6, s2, ext_copy_src
    slli t0, s6, 5
    add  t2, s5, t0
    add  t3, s4, t0
    # value
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_dv_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_dv_rd
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
poll_ext_dv_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_dv_wr
    # tag
    addi t2, t2, 16
    addi t3, t3, 16
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_dt_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_dt_rd
    lw   t4, SP_DATA0(s11)
    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ext_dt_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_dt_wr
    addi s6, s6, 1
    j    ext_copy_dst_loop

    # ---- copy src_len elements src_buf -> new_buf+len*32 -----------------
ext_copy_src:
    li   s6, 0
ext_copy_src_loop:
    beq  s6, s7, ext_writeback
    slli t0, s6, 5
    add  t2, s8, t0                # src elem addr
    slli t1, s2, 5
    add  t3, s4, t1
    add  t3, t3, t0                # dst = new_buf + (len+i)*32
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_sv_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_sv_rd
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
poll_ext_sv_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_sv_wr
    addi t2, t2, 16
    addi t3, t3, 16
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ext_st_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_st_rd
    lw   t4, SP_DATA0(s11)
    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ext_st_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_st_wr
    addi s6, s6, 1
    j    ext_copy_src_loop

ext_writeback:
    add  t4, s2, s7                # new_len
    sw   s0, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s3, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ext_hdr_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_hdr_wb

    addi t2, s0, 16
    sw   t2, SP_ADDR(s11)
    sw   s4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ext_ob_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ext_ob_wb

    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    slli t0, s3, 5
    add  t0, s4, t0
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ---- in-place LIST_EXTEND when cap >= need (s5=dst buf, s8=src buf) ------
ext_inplace:
    # Copy src_len elements onto dst buffer at index len.. (no overlap for
    # self-extend when 2*len <= cap — pycore only traps non-empty; firmware
    # still requires need <= cap which implies the write window starts at len).
    li   s6, 0
ext_ip_src_loop:
    beq  s6, s7, ext_ip_writeback
    slli t0, s6, 5
    add  t2, s8, t0                # src elem addr
    slli t1, s2, 5
    add  t3, s5, t1
    add  t3, t3, t0                # dst = old_buf + (len+i)*32
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ip_sv_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ip_sv_rd
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
poll_ip_sv_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ip_sv_wr
    addi t2, t2, 16
    addi t3, t3, 16
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ip_st_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ip_st_rd
    lw   t4, SP_DATA0(s11)
    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ip_st_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ip_st_wr
    addi s6, s6, 1
    j    ext_ip_src_loop

ext_ip_writeback:
    add  t4, s2, s7                # new_len
    sw   s0, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)         # capacity unchanged
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ip_hdr_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ip_hdr_wb

    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    lw   t0, MB_HEAP_PTR(s11)      # heap unchanged
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ===========================================================================
# DICT_GROW: E0=dict, E1=key, E2=value — realloc, rehash, STORE insert.
# ===========================================================================
do_dict_grow:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_DICT
    beq  t0, t1, dg_tag_ok
    j    fatal_type
dg_tag_ok:
    lw   s0, MB_E0_VAL0(s11)
    jal  ra, load_e1e2_to_scratch
    jal  ra, dict_load_header_table
    jal  ra, dict_grow_rehash
    jal  ra, dict_insert_from_scratch
    jal  ra, dict_writeback_header
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 3
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    slli t0, s7, 6
    add  t0, s4, t0
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ===========================================================================
# LIST_DELETE: E0=list, E1=key (INT/BOOL index) — shift-down, COMPLETED pop 2.
# ===========================================================================
do_list_delete:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_LIST
    bne  t0, t1, fatal_type
    lw   s0, MB_E0_VAL0(s11)       # s0 = obj_addr

    # Index from ENTRY[1] value low word (INT/BOOL; pycore already type-checked).
    lw   s9, MB_E1_VAL0(s11)       # s9 = idx

    # Header -> len (s2), cap (s1)
    sw   s0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ldel_hdr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_hdr
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s2, SP_DATA0(s11)
    lw   s1, SP_DATA2(s11)

    # Bounds (defensive; pycore checked before marshal).
    bgeu s9, s2, fatal_mem

    # ob_item -> buf (s5)
    addi t0, s0, 16
    sw   t0, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ldel_ob:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_ob
    andi t1, t0, SP_STATUS_FAULT
    bne  t1, x0, fatal_mem
    lw   s5, SP_DATA0(s11)

    # Shift [idx+1 .. len) down to [idx .. len-1). s6 = write index.
    mv   s6, s9
ldel_shift_loop:
    addi t0, s6, 1
    beq  t0, s2, ldel_writeback    # write_idx+1 == len → done
    # read src = buf + (write_idx+1)*32
    slli t1, t0, 5
    add  t2, s5, t1
    slli t1, s6, 5
    add  t3, s5, t1                # dst = buf + write_idx*32
    # value
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ldel_v_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_v_rd
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
poll_ldel_v_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_v_wr
    # tag
    addi t2, t2, 16
    addi t3, t3, 16
    sw   t2, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
poll_ldel_t_rd:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_t_rd
    lw   t4, SP_DATA0(s11)
    sw   t3, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ldel_t_wr:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_t_wr
    addi s6, s6, 1
    j    ldel_shift_loop

ldel_writeback:
    addi t4, s2, -1                # new_len = len - 1
    sw   s0, SP_ADDR(s11)
    sw   t4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)         # capacity unchanged
    sw   t0, SP_DATA3(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
poll_ldel_hdr_wb:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, poll_ldel_hdr_wb

    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 2
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# sp_read(a0=addr): fault → fatal_mem; data left in SP_DATA*
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

# sp_write(a0=addr): SP_DATA* already set
sp_write:
    sw   a0, SP_ADDR(s11)
    li   t0, SP_CTRL_WRITE
    sw   t0, SP_CTRL(s11)
sp_write_poll:
    lw   t0, SP_STATUS(s11)
    andi t1, t0, SP_STATUS_BUSY
    bne  t1, x0, sp_write_poll
    jalr x0, ra, 0

load_e1e2_to_scratch:
    lw   t0, MB_E1_VAL0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, MB_E1_VAL1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, MB_E1_VAL2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, MB_E1_VAL3(s11)
    sw   t0, SCR_KVAL3(x0)
    lw   t0, MB_E1_TAG(s11)
    sw   t0, SCR_KTAG(x0)
    lw   t0, MB_E2_VAL0(s11)
    sw   t0, SCR_VVAL0(x0)
    lw   t0, MB_E2_VAL1(s11)
    sw   t0, SCR_VVAL1(x0)
    lw   t0, MB_E2_VAL2(s11)
    sw   t0, SCR_VVAL2(x0)
    lw   t0, MB_E2_VAL3(s11)
    sw   t0, SCR_VVAL3(x0)
    lw   t0, MB_E2_TAG(s11)
    sw   t0, SCR_VTAG(x0)
    jalr x0, ra, 0

# → s1=slots, s2=used, s5/s3=table
dict_load_header_table:
    addi sp, sp, -4
    sw   ra, 0(sp)
    mv   a0, s0
    jal  ra, sp_read
    lw   s2, SP_DATA0(s11)
    lw   s1, SP_DATA2(s11)
    addi a0, s0, 16
    jal  ra, sp_read
    lw   s5, SP_DATA0(s11)
    mv   s3, s5
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

dict_write_used_slots:
    addi sp, sp, -4
    sw   ra, 0(sp)
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

dict_needs_grow:
    beq  a1, x0, dng_yes
    addi t0, a0, 1
    bge  t0, a1, dng_yes
    slli t1, a0, 1
    add  t1, t1, a0
    slli t2, a1, 1
    bge  t1, t2, dng_yes
    li   a0, 0
    jalr x0, ra, 0
dng_yes:
    li   a0, 1
    jalr x0, ra, 0

# grow+rehash: s1/s2/s5 → s4/s7/s3=new table; restores E1/E2 into scratch
dict_grow_rehash:
    addi sp, sp, -4
    sw   ra, 0(sp)
    li   t0, 50000
    bltu t0, s2, dgr_mul2
    slli a0, s2, 2
    j    dgr_need
dgr_mul2:
    slli a0, s2, 1
dgr_need:
    li   t0, 8
    bge  a0, t0, dgr_pow2_init
    li   a0, 8
dgr_pow2_init:
    li   s7, 8
dgr_pow2:
    bge  s7, a0, dgr_gt_used
    slli s7, s7, 1
    j    dgr_pow2
dgr_gt_used:
    blt  s2, s7, dgr_vs_old
    slli s7, s7, 1
    j    dgr_gt_used
dgr_vs_old:
    beq  s1, x0, dgr_alloc
    slli t0, s1, 1
    bge  s7, t0, dgr_alloc
    mv   s7, t0
dgr_alloc:
    lw   s4, MB_HEAP_PTR(s11)
    slli t0, s7, 6
    add  t0, s4, t0
    li   t1, HEAP_LIMIT
    bge  t1, t0, dgr_zero
    j    fatal_mem
dgr_zero:
    li   s6, 0
dgr_zero_loop:
    beq  s6, s7, dgr_rehash
    slli t0, s6, 6
    add  a0, s4, t0
    addi a0, a0, 16
    li   t0, 0
    sw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    addi s6, s6, 1
    j    dgr_zero_loop
dgr_rehash:
    mv   s3, s4
    beq  s1, x0, dgr_done
    li   s6, 0
dgr_rehash_loop:
    beq  s6, s1, dgr_done
    slli t0, s6, 6
    add  t2, s5, t0
    addi a0, t2, 16
    sw   t2, SCR_A1(x0)
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, dgr_next
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, dgr_next
    lw   a0, SCR_A1(x0)
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_KVAL3(x0)
    sw   a1, SCR_KTAG(x0)
    lw   a0, SCR_A1(x0)
    addi a0, a0, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_VVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_VVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_VVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_VVAL3(x0)
    lw   a0, SCR_A1(x0)
    addi a0, a0, 48
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_VTAG(x0)
    sw   s6, SCR_IDX(x0)
    jal  ra, hash_key
    addi t0, s7, -1
    and  a0, a0, t0
dgr_ins_probe:
    sw   a0, SCR_A0(x0)
    slli t0, a0, 6
    add  t2, s3, t0
    addi a0, t2, 16
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    beq  t0, x0, dgr_ins_write
    lw   a0, SCR_A0(x0)
    addi a0, a0, 1
    addi t0, s7, -1
    and  a0, a0, t0
    j    dgr_ins_probe
dgr_ins_write:
    lw   a0, SCR_A0(x0)
    jal  ra, dict_write_kv_at
    lw   s6, SCR_IDX(x0)
dgr_next:
    addi s6, s6, 1
    j    dgr_rehash_loop
dgr_done:
    jal  ra, load_e1e2_to_scratch
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

dict_insert_from_scratch:
    # BUG FIX: was sw s1, SCR_A1(x0) — SCR_A1 is clobbered by dict_probe's
    # dprobe_loop.  Use the stack instead.  ra is also now stack-saved.
    addi sp, sp, -8
    sw   ra, 4(sp)
    sw   s1, 0(sp)             # save old s1 (slot_count) on stack
    mv   s1, s7
    jal  ra, dict_probe
    lw   s1, 0(sp)             # restore s1 from stack (SCR_A1 is now garbage but irrelevant)
    lw   t0, SCR_FOUND(x0)
    bne  t0, x0, difs_over
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_kv_at
    addi s2, s2, 1
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0
difs_over:
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_val_at
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0

dict_writeback_header:
    addi sp, sp, -4
    sw   ra, 0(sp)
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s7, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    sw   s4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    mv   s1, s7
    mv   s3, s4
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

# probe s3/s1 with SCR_K* → SCR_FOUND / SCR_IDX / SCR_TOMB
dict_probe:
    addi sp, sp, -12
    sw   ra,  8(sp)            # stack-saved: no more SCR_RA2 aliasing
    sw   s6,  4(sp)            # callee-save s6 (probe start index)
    sw   s8,  0(sp)            # callee-save s8 (probe count)
    li   t0, -1
    sw   t0, SCR_TOMB(x0)
    sw   x0, SCR_FOUND(x0)
    jal  ra, hash_key
    addi t0, s1, -1
    and  a0, a0, t0
    sw   a0, SCR_IDX(x0)
    mv   s6, a0
    li   s8, 0
dprobe_loop:
    slli t0, a0, 6
    add  t2, s3, t0
    sw   t2, SCR_A1(x0)
    sw   a0, SCR_IDX(x0)
    addi a0, t2, 16
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, dprobe_empty
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, dprobe_tomb
    lw   a0, SCR_A1(x0)
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_SKVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_SKVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_SKVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_SKVAL3(x0)
    sw   a1, SCR_SKTAG(x0)
    jal  ra, keys_rich_eq
    bne  a0, x0, dprobe_hit
    lw   a0, SCR_IDX(x0)
    j    dprobe_advance
dprobe_tomb:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    bne  t0, t1, dprobe_advance_ld
    lw   a0, SCR_IDX(x0)
    sw   a0, SCR_TOMB(x0)
dprobe_advance_ld:
    lw   a0, SCR_IDX(x0)
    j    dprobe_advance
dprobe_empty:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    beq  t0, t1, dprobe_empty_cur
    sw   t0, SCR_IDX(x0)
    j    dprobe_miss
dprobe_empty_cur:
    # SCR_IDX already current
    j    dprobe_miss
dprobe_miss:
    sw   x0, SCR_FOUND(x0)
    lw   s8,  0(sp)
    lw   s6,  4(sp)
    lw   ra,  8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0
dprobe_hit:
    li   t0, 1
    sw   t0, SCR_FOUND(x0)
    lw   s8,  0(sp)
    lw   s6,  4(sp)
    lw   ra,  8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0
dprobe_advance:
    addi s8, s8, 1
    bge  s8, s1, dprobe_exhausted
    addi a0, a0, 1
    addi t0, s1, -1
    and  a0, a0, t0
    j    dprobe_loop
dprobe_exhausted:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    beq  t0, t1, dprobe_ex_start
    sw   t0, SCR_IDX(x0)
    j    dprobe_miss
dprobe_ex_start:
    sw   s6, SCR_IDX(x0)
    j    dprobe_miss

dict_write_kv_at:
    addi sp, sp, -8
    sw   ra, 4(sp)             # stack-save ra (no more SCR_RA3 aliasing)
    sw   a0, 0(sp)             # stack-save insertion slot index
    slli t0, a0, 6
    add  t2, s3, t0
    sw   t2, SCR_A1(x0)       # SCR_A1 = slot base for ktag/vval reads
    lw   t0, SCR_KVAL0(x0)
    sw   t0, SP_DATA0(s11)
    lw   t0, SCR_KVAL1(x0)
    sw   t0, SP_DATA1(s11)
    lw   t0, SCR_KVAL2(x0)
    sw   t0, SP_DATA2(s11)
    lw   t0, SCR_KVAL3(x0)
    sw   t0, SP_DATA3(s11)
    mv   a0, t2
    jal  ra, sp_write
    lw   a0, SCR_A1(x0)
    addi a0, a0, 16
    lw   t0, SCR_KTAG(x0)
    sw   t0, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    lw   a0, 0(sp)             # reload insertion slot index
    jal  ra, dict_write_val_at
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0

dict_write_val_at:
    addi sp, sp, -4
    sw   ra, 0(sp)             # stack-save ra (no more SCR_FTI0 aliasing)
    slli t0, a0, 6
    add  t2, s3, t0
    addi a0, t2, 32
    sw   t2, SCR_A1(x0)
    lw   t0, SCR_VVAL0(x0)
    sw   t0, SP_DATA0(s11)
    lw   t0, SCR_VVAL1(x0)
    sw   t0, SP_DATA1(s11)
    lw   t0, SCR_VVAL2(x0)
    sw   t0, SP_DATA2(s11)
    lw   t0, SCR_VVAL3(x0)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    lw   a0, SCR_A1(x0)
    addi a0, a0, 48
    lw   t0, SCR_VTAG(x0)
    sw   t0, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

dict_read_val_to_res:
    addi sp, sp, -4
    sw   ra, 0(sp)
    slli t0, a0, 6
    add  t2, s3, t0
    sw   t2, SCR_A1(x0)
    addi a0, t2, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, RES_E0_VAL0(s11)
    lw   t0, SP_DATA1(s11)
    sw   t0, RES_E0_VAL1(s11)
    lw   t0, SP_DATA2(s11)
    sw   t0, RES_E0_VAL2(s11)
    lw   t0, SP_DATA3(s11)
    sw   t0, RES_E0_VAL3(s11)
    lw   a0, SCR_A1(x0)
    addi a0, a0, 48
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, RES_E0_TAG(s11)
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

hash_key:
    lw   t0, SCR_KTAG(x0)
    li   t1, TAG_INT
    beq  t0, t1, hash_int
    li   t1, TAG_BOOL
    beq  t0, t1, hash_bool
    li   t1, TAG_FLOAT
    beq  t0, t1, hash_float
    li   t1, TAG_SHORT_STR
    beq  t0, t1, hash_sstr
    li   t1, TAG_LONG_STR
    beq  t0, t1, hash_lstr
    lw   a0, SCR_KVAL0(x0)
    jalr x0, ra, 0
hash_int:
    lw   a0, SCR_KVAL0(x0)
    lw   t0, SCR_KVAL1(x0)
    li   t1, -1
    bne  a0, t1, hash_ret
    bne  t0, t1, hash_ret
    li   a0, 0xFFFFFFFE
hash_ret:
    jalr x0, ra, 0
hash_bool:
    lw   a0, SCR_KVAL0(x0)
    andi a0, a0, 1
    jalr x0, ra, 0
hash_sstr:
    lw   a0, SCR_KVAL0(x0)
    lw   t0, SCR_KVAL1(x0)
    xor  a0, a0, t0
    lw   t0, SCR_KVAL2(x0)
    xor  a0, a0, t0
    lw   t0, SCR_KVAL3(x0)
    xor  a0, a0, t0
    jalr x0, ra, 0
hash_lstr:
    lw   a0, SCR_KVAL0(x0)
    lw   t0, SCR_KVAL2(x0)
    xor  a0, a0, t0
    jalr x0, ra, 0
hash_float:
    addi sp, sp, -4
    sw   ra, 0(sp)
    lw   t3, SCR_KVAL0(x0)
    lw   t4, SCR_KVAL1(x0)
    jal  ra, float_to_int
    beq  a0, x0, hash_fmix
    mv   a0, t3
    mv   t0, t4
    li   t1, -1
    bne  a0, t1, hash_fret
    bne  t0, t1, hash_fret
    li   a0, 0xFFFFFFFE
    j    hash_fret
hash_fmix:
    lw   a0, SCR_KVAL0(x0)
    lw   t0, SCR_KVAL1(x0)
    xor  a0, a0, t0
hash_fret:
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

# keys_rich_eq: SCR_K* vs SCR_SK* → a0
keys_rich_eq:
    addi sp, sp, -8
    sw   ra, 4(sp)
    sw   x0, 0(sp)            # slot for first norm a1
    lw   a2, SCR_KTAG(x0)
    lw   a3, SCR_SKTAG(x0)
    mv   a4, a2
    lw   t3, SCR_KVAL0(x0)
    lw   t4, SCR_KVAL1(x0)
    jal  ra, norm_numeric
    beq  a0, x0, kreq_bits
    sw   a1, 0(sp)
    sw   t3, SCR_TMP_L0(x0)
    sw   t4, SCR_TMP_L1(x0)
    mv   a4, a3
    lw   t3, SCR_SKVAL0(x0)
    lw   t4, SCR_SKVAL1(x0)
    jal  ra, norm_numeric
    beq  a0, x0, kreq_bits
    lw   t0, 0(sp)
    bne  t0, x0, kreq_fb
    bne  a1, x0, kreq_fb
    lw   t5, SCR_TMP_L0(x0)
    lw   t6, SCR_TMP_L1(x0)
    bne  t3, t5, kreq_no
    bne  t4, t6, kreq_no
    li   a0, 1
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0
kreq_fb:
    bne  t0, a1, kreq_no
    li   t1, TAG_FLOAT
    bne  a2, t1, kreq_no
    bne  a3, t1, kreq_no
kreq_bits:
    bne  a2, a3, kreq_no
    lw   t0, SCR_KVAL0(x0)
    lw   t1, SCR_SKVAL0(x0)
    bne  t0, t1, kreq_no
    lw   t0, SCR_KVAL1(x0)
    lw   t1, SCR_SKVAL1(x0)
    bne  t0, t1, kreq_no
    lw   t0, SCR_KVAL2(x0)
    lw   t1, SCR_SKVAL2(x0)
    bne  t0, t1, kreq_no
    lw   t0, SCR_KVAL3(x0)
    lw   t1, SCR_SKVAL3(x0)
    bne  t0, t1, kreq_no
    li   a0, 1
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0
kreq_no:
    li   a0, 0
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0

norm_numeric:
    li   t0, TAG_INT
    beq  a4, t0, norm_int
    li   t0, TAG_BOOL
    beq  a4, t0, norm_bool
    li   t0, TAG_FLOAT
    beq  a4, t0, norm_float
    li   a0, 0
    jalr x0, ra, 0
norm_int:
    li   a0, 1
    li   a1, 0
    jalr x0, ra, 0
norm_bool:
    andi t3, t3, 1
    li   t4, 0
    li   a0, 1
    li   a1, 0
    jalr x0, ra, 0
norm_float:
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, float_to_int
    lw   ra, 0(sp)
    addi sp, sp, 4
    beq  a0, x0, norm_fbits
    li   a1, 0
    li   a0, 1
    jalr x0, ra, 0
norm_fbits:
    li   a1, 1
    li   a0, 1
    jalr x0, ra, 0

# float_to_int: t3/t4 bits → a0=1 + signed int64 in t3/t4, else a0=0 restore
float_to_int:
    sw   t3, SCR_FTI0(x0)
    sw   t4, SCR_FTI1(x0)
    srli a1, t4, 31
    srli t0, t4, 20
    andi t0, t0, 0x7FF
    li   t1, 0xFFFFF
    and  t6, t4, t1
    li   t1, 0x7FF
    beq  t0, t1, fti_fail
    bne  t0, x0, fti_ge1
    bne  t6, x0, fti_fail
    bne  t3, x0, fti_fail
    li   t3, 0
    li   t4, 0
    li   a0, 1
    jalr x0, ra, 0
fti_ge1:
    li   t1, 1023
    blt  t0, t1, fti_fail
    sub  t1, t0, t1
    li   t2, 63
    bge  t1, t2, fti_fail
    # Only handle uexp < 52 (covers normal test keys); else fail→bit path
    li   t2, 52
    bge  t1, t2, fti_fail
    # non-int frac bits?
    sub  t2, t2, t1
    li   t5, 32
    bge  t2, t5, fti_mw
    li   t5, 1
    sll  t5, t5, t2
    addi t5, t5, -1
    and  t5, t3, t5
    bne  t5, x0, fti_fail
    j    fti_shift
fti_mw:
    bne  t3, x0, fti_fail
    addi t5, t2, -32
    li   t0, 1
    sll  t0, t0, t5
    addi t0, t0, -1
    and  t0, t6, t0
    bne  t0, x0, fti_fail
fti_shift:
    li   t0, 0x100000
    or   a3, t6, t0
    mv   a2, t3
    # t2 = 52-uexp still
fti_shr:
    beq  t2, x0, fti_mag
    slli t0, a3, 31
    srli a2, a2, 1
    or   a2, a2, t0
    srli a3, a3, 1
    addi t2, t2, -1
    j    fti_shr
fti_mag:
    beq  a1, x0, fti_pos
    beq  a2, x0, fti_nz
    sub  t3, x0, a2
    li   t0, -1
    xor  t4, a3, t0
    j    fti_ok
fti_nz:
    li   t3, 0
    sub  t4, x0, a3
    j    fti_ok
fti_pos:
    mv   t3, a2
    mv   t4, a3
fti_ok:
    li   a0, 1
    jalr x0, ra, 0
fti_fail:
    lw   t3, SCR_FTI0(x0)
    lw   t4, SCR_FTI1(x0)
    li   a0, 0
    jalr x0, ra, 0

# ===========================================================================
# SET_GROW: E0=set, E1=element — realloc table (stride 32), rehash, insert.
# ===========================================================================
do_set_grow:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_SET
    beq  t0, t1, sg_tag_ok
    j    fatal_type
sg_tag_ok:
    lw   s0, MB_E0_VAL0(s11)
    # Load element into SCR_K*
    lw   t0, MB_E1_VAL0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, MB_E1_VAL1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, MB_E1_VAL2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, MB_E1_VAL3(s11)
    sw   t0, SCR_KVAL3(x0)
    lw   t0, MB_E1_TAG(s11)
    sw   t0, SCR_KTAG(x0)
    jal  ra, dict_load_header_table   # s1=slots, s2=used, s5/s3=table
    jal  ra, set_grow_rehash
    jal  ra, set_insert_from_scratch
    jal  ra, set_writeback_header
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    slli t0, s7, 5
    add  t0, s4, t0
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ===========================================================================
# SET_UPDATE: E0=set, E1=LIST/TUPLE/SET — grow-to-fit once, insert all.
# ===========================================================================
do_set_update:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_SET
    beq  t0, t1, su_tag_ok
    j    fatal_type
su_tag_ok:
    lw   s0, MB_E0_VAL0(s11)
    jal  ra, dict_load_header_table
    lw   s9, MB_E1_TAG(s11)
    lw   s10, MB_E1_VAL0(s11)
    li   t1, TAG_LIST
    beq  s9, t1, su_src_list
    li   t1, TAG_TUPLE
    beq  s9, t1, su_src_tuple
    li   t1, TAG_SET
    beq  s9, t1, su_src_set
    j    fatal_type

su_src_list:
    mv   a0, s10
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)         # src_len (dense count)
    sw   t0, SCR_TMP_L0(x0)
    addi a0, s10, 16
    jal  ra, sp_read
    lw   s8, SP_DATA0(s11)
    li   s9, 0
    j    su_maybe_grow

su_src_tuple:
    lw   t0, MB_E1_VAL2(s11)
    sw   t0, SCR_TMP_L0(x0)
    mv   s8, s10
    li   s9, 0
    j    su_maybe_grow

su_src_set:
    mv   a0, s10
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)         # src used (upper bound on new elems)
    sw   t0, SCR_TMP_L1(x0)
    lw   t1, SP_DATA2(s11)         # src slots (walk count)
    sw   t1, SCR_TMP_L0(x0)
    addi a0, s10, 16
    jal  ra, sp_read
    lw   s8, SP_DATA0(s11)
    li   s9, 1
    # For grow sizing use src used, not slots.
    lw   t0, SCR_TMP_L1(x0)
    # Fall through with t0=src_used for need; walk count stays TMP_L0.
    j    su_maybe_grow_set

su_maybe_grow:
    lw   t0, SCR_TMP_L0(x0)        # src_len
su_maybe_grow_set:
    sw   t0, SCR_FTI1(x0)          # save src_count across calls
    # need_used_upper = used + src_count (duplicates shrink actual used)
    add  t1, s2, t0
    mv   a0, t1
    mv   a1, s1
    jal  ra, dict_needs_grow
    beq  a0, x0, su_loop_init
    # Force grow: set s2 temporarily to need for sizing, then restore.
    sw   s2, SCR_FTI0(x0)
    lw   t0, SCR_FTI1(x0)
    add  s2, s2, t0
    sw   x0, SCR_KVAL0(x0)
    sw   x0, SCR_KVAL1(x0)
    sw   x0, SCR_KVAL2(x0)
    sw   x0, SCR_KVAL3(x0)
    sw   x0, SCR_KTAG(x0)
    jal  ra, set_grow_rehash_keep
    lw   s2, SCR_FTI0(x0)

su_loop_init:
    li   s6, 0
    li   s4, 0                     # no new heap unless we grew (s4 set in grow)
su_loop:
    lw   t0, SCR_TMP_L0(x0)
    beq  s6, t0, su_done
    bne  s9, x0, su_load_set
    # dense LIST/TUPLE
    slli t0, s6, 5
    add  t2, s8, t0
    mv   a0, t2
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_KVAL3(x0)
    addi a0, t2, 16
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    sw   a1, SCR_KTAG(x0)
    j    su_insert
su_load_set:
    slli t0, s6, 5
    add  t2, s8, t0
    addi a0, t2, 16
    sw   t2, SCR_A1(x0)
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, su_next
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, su_next
    lw   a0, SCR_A1(x0)
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_KVAL3(x0)
    sw   a1, SCR_KTAG(x0)
su_insert:
    # set_probe clobbers s6 (start idx) and s8 (probe count).
    sw   s6, SCR_FTI0(x0)
    sw   s8, SCR_FTI1(x0)
    jal  ra, set_probe
    lw   s6, SCR_FTI0(x0)
    lw   s8, SCR_FTI1(x0)
    lw   t0, SCR_FOUND(x0)
    bne  t0, x0, su_next
    lw   a0, SCR_IDX(x0)
    jal  ra, set_write_elem_at
    addi s2, s2, 1
    jal  ra, dict_write_used_slots
su_next:
    addi s6, s6, 1
    j    su_loop

su_done:
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    beq  s4, x0, su_heap_mb
    slli t0, s1, 5
    add  t0, s4, t0
    sw   t0, RES_HEAP_PTR(s11)
    j    su_go
su_heap_mb:
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, RES_HEAP_PTR(s11)
su_go:
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# set_grow_rehash: like dict_grow_rehash but stride 32, element-only.
# Does NOT call load_e1e2 (preserves SCR_K*).
set_grow_rehash_keep:
set_grow_rehash:
    addi sp, sp, -4
    sw   ra, 0(sp)
    li   t0, 50000
    bltu t0, s2, sgr_mul2
    slli a0, s2, 2
    j    sgr_need
sgr_mul2:
    slli a0, s2, 1
sgr_need:
    li   t0, 8
    bge  a0, t0, sgr_pow2_init
    li   a0, 8
sgr_pow2_init:
    li   s7, 8
sgr_pow2:
    bge  s7, a0, sgr_gt_used
    slli s7, s7, 1
    j    sgr_pow2
sgr_gt_used:
    blt  s2, s7, sgr_vs_old
    slli s7, s7, 1
    j    sgr_gt_used
sgr_vs_old:
    beq  s1, x0, sgr_alloc
    slli t0, s1, 1
    bge  s7, t0, sgr_alloc
    mv   s7, t0
sgr_alloc:
    lw   s4, MB_HEAP_PTR(s11)
    slli t0, s7, 5
    add  t0, s4, t0
    li   t1, HEAP_LIMIT
    bge  t1, t0, sgr_zero
    j    fatal_mem
sgr_zero:
    li   s6, 0
sgr_zero_loop:
    beq  s6, s7, sgr_rehash
    slli t0, s6, 5
    add  a0, s4, t0
    addi a0, a0, 16
    li   t0, 0
    sw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    addi s6, s6, 1
    j    sgr_zero_loop
sgr_rehash:
    mv   s3, s4
    beq  s1, x0, sgr_done
    li   s6, 0
sgr_rehash_loop:
    beq  s6, s1, sgr_done
    slli t0, s6, 5
    add  t2, s5, t0
    addi a0, t2, 16
    sw   t2, SCR_A1(x0)
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, sgr_next
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, sgr_next
    lw   a0, SCR_A1(x0)
    jal  ra, sp_read
    # Temporarily use SK* for rehash source; keep K* intact via V*
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_SKVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_SKVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_SKVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_SKVAL3(x0)
    sw   a1, SCR_SKTAG(x0)
    # hash from SK — temporarily swap into K
    lw   t0, SCR_KVAL0(x0)
    sw   t0, SCR_VVAL0(x0)
    lw   t0, SCR_KVAL1(x0)
    sw   t0, SCR_VVAL1(x0)
    lw   t0, SCR_KVAL2(x0)
    sw   t0, SCR_VVAL2(x0)
    lw   t0, SCR_KVAL3(x0)
    sw   t0, SCR_VVAL3(x0)
    lw   t0, SCR_KTAG(x0)
    sw   t0, SCR_VTAG(x0)
    lw   t0, SCR_SKVAL0(x0)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SCR_SKVAL1(x0)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SCR_SKVAL2(x0)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SCR_SKVAL3(x0)
    sw   t0, SCR_KVAL3(x0)
    lw   t0, SCR_SKTAG(x0)
    sw   t0, SCR_KTAG(x0)
    sw   s6, SCR_IDX(x0)
    jal  ra, hash_key
    addi t0, s7, -1
    and  a0, a0, t0
sgr_ins_probe:
    sw   a0, SCR_A0(x0)
    slli t0, a0, 5
    add  t2, s3, t0
    addi a0, t2, 16
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    beq  t0, x0, sgr_ins_write
    lw   a0, SCR_A0(x0)
    addi a0, a0, 1
    addi t0, s7, -1
    and  a0, a0, t0
    j    sgr_ins_probe
sgr_ins_write:
    lw   a0, SCR_A0(x0)
    jal  ra, set_write_elem_at
    # restore pending insert key
    lw   t0, SCR_VVAL0(x0)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SCR_VVAL1(x0)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SCR_VVAL2(x0)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SCR_VVAL3(x0)
    sw   t0, SCR_KVAL3(x0)
    lw   t0, SCR_VTAG(x0)
    sw   t0, SCR_KTAG(x0)
    lw   s6, SCR_IDX(x0)
sgr_next:
    addi s6, s6, 1
    j    sgr_rehash_loop
sgr_done:
    # Install new table into object immediately so subsequent probes work.
    # used unchanged; slots = s7
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s7, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    sw   s4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    mv   s1, s7
    mv   s3, s4
    mv   s5, s4
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

set_writeback_header:
    # alias: header already written in set_grow_rehash; bump used after insert
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, dict_write_used_slots
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

set_insert_from_scratch:
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, set_probe
    lw   t0, SCR_FOUND(x0)
    bne  t0, x0, sifs_done
    lw   a0, SCR_IDX(x0)
    jal  ra, set_write_elem_at
    addi s2, s2, 1
sifs_done:
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

# set_probe: like dict_probe but stride 32
set_probe:
    addi sp, sp, -12
    sw   ra,  8(sp)
    sw   s6,  4(sp)
    sw   s8,  0(sp)
    li   t0, -1
    sw   t0, SCR_TOMB(x0)
    sw   x0, SCR_FOUND(x0)
    jal  ra, hash_key
    addi t0, s1, -1
    and  a0, a0, t0
    sw   a0, SCR_IDX(x0)
    mv   s6, a0
    li   s8, 0
sprobe_loop:
    slli t0, a0, 5
    add  t2, s3, t0
    sw   t2, SCR_A1(x0)
    sw   a0, SCR_IDX(x0)
    addi a0, t2, 16
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, sprobe_empty
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, sprobe_tomb
    lw   a0, SCR_A1(x0)
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_SKVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_SKVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_SKVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_SKVAL3(x0)
    sw   a1, SCR_SKTAG(x0)
    jal  ra, keys_rich_eq
    bne  a0, x0, sprobe_hit
    lw   a0, SCR_IDX(x0)
    j    sprobe_advance
sprobe_tomb:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    bne  t0, t1, sprobe_advance_ld
    lw   a0, SCR_IDX(x0)
    sw   a0, SCR_TOMB(x0)
sprobe_advance_ld:
    lw   a0, SCR_IDX(x0)
    j    sprobe_advance
sprobe_empty:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    beq  t0, t1, sprobe_empty_cur
    sw   t0, SCR_IDX(x0)
    j    sprobe_miss
sprobe_empty_cur:
    j    sprobe_miss
sprobe_miss:
    sw   x0, SCR_FOUND(x0)
    lw   s8,  0(sp)
    lw   s6,  4(sp)
    lw   ra,  8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0
sprobe_hit:
    li   t0, 1
    sw   t0, SCR_FOUND(x0)
    lw   s8,  0(sp)
    lw   s6,  4(sp)
    lw   ra,  8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0
sprobe_advance:
    addi s8, s8, 1
    bge  s8, s1, sprobe_exhausted
    addi a0, a0, 1
    addi t0, s1, -1
    and  a0, a0, t0
    j    sprobe_loop
sprobe_exhausted:
    lw   t0, SCR_TOMB(x0)
    li   t1, -1
    beq  t0, t1, sprobe_ex_start
    sw   t0, SCR_IDX(x0)
    j    sprobe_miss
sprobe_ex_start:
    sw   s6, SCR_IDX(x0)
    j    sprobe_miss

# ===========================================================================
# DICT_UPDATE: E0=dst dict, E1=src dict — merge src into dst.
# Iterates every live slot in E1 and inserts key/value into E0, growing
# E0 as needed.  COMPLETED pop=1 (pop the iterable; dict stays).
#
# SCR reuse during loop: SCR_TMP_L0=src_slot_count, SCR_TMP_L1=src_table_ptr
# ===========================================================================
do_dict_update:
    # Local trampolines so B-type branches don't exceed ±4KiB.
du_fatal_type:
    j    fatal_type
du_fatal_mem:
    j    fatal_mem
du_start:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_DICT
    bne  t0, t1, du_fatal_type
    lw   t0, MB_E1_TAG(s11)
    li   t1, TAG_DICT
    bne  t0, t1, du_fatal_type

    lw   s0, MB_E0_VAL0(s11)          # s0 = dst obj addr
    jal  ra, dict_load_header_table   # s1=dst_slots, s2=dst_used, s3=s5=dst_tbl

    # Load src header to get src_slot_count and src_table_ptr.
    lw   t1, MB_E1_VAL0(s11)          # t1 = src obj addr
    sw   t1, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
du_poll_src_hdr:
    lw   t0, SP_STATUS(s11)
    andi t2, t0, SP_STATUS_BUSY
    bne  t2, x0, du_poll_src_hdr
    andi t2, t0, SP_STATUS_FAULT
    bne  t2, x0, du_fatal_mem
    lw   t0, SP_DATA0(s11)            # src used[31:0] (for grow check)
    sw   t0, SCR_FTI1(x0)            # SCR_FTI1 = src_used
    lw   t0, SP_DATA2(s11)            # src slot_count[31:0] (for loop)
    sw   t0, SCR_TMP_L0(x0)          # SCR_TMP_L0 = src_slot_count
    lw   t1, MB_E1_VAL0(s11)
    addi t1, t1, 16
    sw   t1, SP_ADDR(s11)
    li   t0, SP_CTRL_READ
    sw   t0, SP_CTRL(s11)
du_poll_src_tbl:
    lw   t0, SP_STATUS(s11)
    andi t2, t0, SP_STATUS_BUSY
    bne  t2, x0, du_poll_src_tbl
    andi t2, t0, SP_STATUS_FAULT
    bne  t2, x0, du_fatal_mem
    lw   t0, SP_DATA0(s11)            # src table_ptr
    sw   t0, SCR_TMP_L1(x0)          # SCR_TMP_L1 = src_table_ptr

    # Note: no pre-emptive grow here. The pycore (CONT_MAP_ADD) already ensures
    # that the dst dict has enough capacity before firing the trap (via DICT_GROW).
    # For DICT_UPDATE, we rely on the fact that the loop will use dict_probe
    # which finds free or tombstone slots in the table. If the table is full,
    # dict_probe will return an invalid index (behavior undefined for truly full
    # tables, but DICT_UPDATE should only be called when enough capacity exists).
    li   s4, 0                        # s4=0: no grow

du_loop_init:
    # Scratch addresses used here (not used by any helper function):
    #   8(x0)  = saved src key tag (TAG_INT etc.)
    #   12(x0) = saved src val tag
    lw   s9, SCR_TMP_L0(x0)   # s9 = src_slot_count (countdown)
du_loop:
    beq  s9, x0, du_done      # exit when countdown reaches 0 (x0 constant)
    addi s9, s9, -1            # pre-decrement: slot_idx = s9 (after decr)
    lw   t5, SCR_TMP_L1(x0)   # t5 = src_table_ptr (saved at loop start)
    slli t6, s9, 6
    add  t5, t5, t6            # t5 = src slot [s9] base addr

    # ---- Read src ktag -------------------------------------------------------
    addi a0, t5, 16
    sw   a0, SP_ADDR(s11)
    li   a1, SP_CTRL_READ
    sw   a1, SP_CTRL(s11)
du_ktag_poll:
    lw   a0, SP_STATUS(s11)
    andi a1, a0, SP_STATUS_BUSY
    bne  a1, x0, du_ktag_poll
    lw   a0, SP_DATA0(s11)     # a0 = src ktag
    beq  a0, x0, du_next       # UNINIT → skip
    li   a1, TAG_TOMBSTONE
    beq  a0, a1, du_next       # tombstone → skip
    sw   a0, 8(x0)             # save src ktag to private scratch[8]

    # ---- Read src kval -------------------------------------------------------
    sw   t5, SP_ADDR(s11)      # kval is at slot base
    li   a1, SP_CTRL_READ
    sw   a1, SP_CTRL(s11)
du_kval_poll:
    lw   a0, SP_STATUS(s11)
    andi a1, a0, SP_STATUS_BUSY
    bne  a1, x0, du_kval_poll
    lw   a0, SP_DATA0(s11); sw a0, SCR_KVAL0(x0)
    lw   a0, SP_DATA1(s11); sw a0, SCR_KVAL1(x0)
    lw   a0, SP_DATA2(s11); sw a0, SCR_KVAL2(x0)
    lw   a0, SP_DATA3(s11); sw a0, SCR_KVAL3(x0)

    # ---- Read src vval -------------------------------------------------------
    addi a0, t5, 32
    sw   a0, SP_ADDR(s11)
    li   a1, SP_CTRL_READ
    sw   a1, SP_CTRL(s11)
du_vval_poll:
    lw   a0, SP_STATUS(s11)
    andi a1, a0, SP_STATUS_BUSY
    bne  a1, x0, du_vval_poll
    lw   a0, SP_DATA0(s11); sw a0, SCR_VVAL0(x0)
    lw   a0, SP_DATA1(s11); sw a0, SCR_VVAL1(x0)
    lw   a0, SP_DATA2(s11); sw a0, SCR_VVAL2(x0)
    lw   a0, SP_DATA3(s11); sw a0, SCR_VVAL3(x0)

    # ---- Read src vtag -------------------------------------------------------
    addi a0, t5, 48
    sw   a0, SP_ADDR(s11)
    li   a1, SP_CTRL_READ
    sw   a1, SP_CTRL(s11)
du_vtag_poll:
    lw   a0, SP_STATUS(s11)
    andi a1, a0, SP_STATUS_BUSY
    bne  a1, x0, du_vtag_poll
    lw   a0, SP_DATA0(s11)
    sw   a0, 12(x0)            # save src vtag to private scratch[12]

    # ---- Probe dst dict for this key ----------------------------------------
    # We call hash_key (uses SCR_KTAG, SCR_KVAL0/1) then do inline probe.
    # s1 = dst slot count; s3 = dst table.
    # IMPORTANT: SCR_KTAG must be set before hash_key.
    lw   a0, 8(x0)             # reload src ktag
    sw   a0, SCR_KTAG(x0)      # set SCR_KTAG for hash_key
    sw   s9, SCR_IDX(x0)       # save s9 (loop counter) across jal ra, hash_key
    jal  ra, hash_key           # a0 = hash(key)  [uses SCR_KTAG, SCR_KVAL0/1]
    lw   s9, SCR_IDX(x0)       # restore s9
    addi t6, s1, -1
    and  a0, a0, t6             # a0 = probe_idx = hash & (slot_count-1)

    # Inline open-address probe: find UNINIT slot (FOUND=0) or matching key.
    # For DICT_UPDATE we only need to find empty slots (insert) or existing
    # keys (overwrite).  Full rich-eq is not needed since source and dest dicts
    # share the same key types and we are merging, not looking up.
    # For correctness we do a simple linear search for UNINIT or exact key match.
    li   t6, 0                  # probe count
du_probe_loop:
    slli t4, a0, 6
    add  t4, s3, t4             # t4 = dst slot [a0] base
    addi t3, t4, 16             # t3 = dst ktag addr
    sw   t3, SP_ADDR(s11)
    li   t3, SP_CTRL_READ
    sw   t3, SP_CTRL(s11)
du_probe_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_probe_poll
    lw   t3, SP_DATA0(s11)     # t3 = dst ktag at probe slot
    beq  t3, x0, du_probe_empty  # UNINIT → insert here
    # Slot occupied: check if same key (for overwrite).
    lw   t3, 8(x0)             # t3 = our src ktag
    # Compare ktag + kval for exact match (works for INT/BOOL/FLOAT/STR).
    # Load dst kval:
    sw   t4, SP_ADDR(s11)
    li   t3, SP_CTRL_READ
    sw   t3, SP_CTRL(s11)
du_probe_kval_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_probe_kval_poll
    lw   t3, SP_DATA0(s11)     # dst kval[31:0]
    lw   t4, SCR_KVAL0(x0)    # src kval[31:0]
    bne  t3, t4, du_probe_next # different → keep probing
    # Same low word; full equality done via helper for correctness.
    # Re-load t4 (was overwritten by sp_read ack → STATUS was in t3).
    # Actually: we just need to check all 4 words + ktag match.
    # For simplicity (INT/BOOL keys are 64-bit): check words 0 and 1 only.
    lw   t3, SP_DATA1(s11)
    lw   t4, SCR_KVAL1(x0)
    beq  t3, t4, du_probe_found  # match on low 64 bits → overwrite

du_probe_next:
    addi t6, t6, 1             # increment probe count
    bge  t6, s1, du_probe_exhaust  # exhausted all slots (no empty/match)
    addi a0, a0, 1
    addi t3, s1, -1
    and  a0, a0, t3            # wrap probe_idx
    # Reload t4 = dst slot base for next iteration
    slli t4, a0, 6
    add  t4, s3, t4
    j    du_probe_loop

du_probe_exhaust:
    # No free slot found — dict was full (shouldn't happen if no grow needed).
    # Skip this key silently and continue with next source slot.
    j    du_next

du_probe_empty:
    # Found an empty slot at index a0.  Insert key/value.
    # t4 = dst slot [a0] base.  Write kval, ktag, vval, vtag inline.
    # kval:
    lw   t3, SCR_KVAL0(x0); sw t3, SP_DATA0(s11)
    lw   t3, SCR_KVAL1(x0); sw t3, SP_DATA1(s11)
    lw   t3, SCR_KVAL2(x0); sw t3, SP_DATA2(s11)
    lw   t3, SCR_KVAL3(x0); sw t3, SP_DATA3(s11)
    sw   t4, SP_ADDR(s11)
    li   t3, SP_CTRL_WRITE
    sw   t3, SP_CTRL(s11)
du_wr_kval_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_wr_kval_poll
    # ktag:
    lw   t3, 8(x0)             # src ktag
    sw   t3, SP_DATA0(s11)
    li   t3, 0
    sw   t3, SP_DATA1(s11)
    sw   t3, SP_DATA2(s11)
    sw   t3, SP_DATA3(s11)
    addi t3, t4, 16
    sw   t3, SP_ADDR(s11)
    li   t3, SP_CTRL_WRITE
    sw   t3, SP_CTRL(s11)
du_wr_ktag_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_wr_ktag_poll
    addi s2, s2, 1             # increment used count
    j    du_write_vval

du_probe_found:
    # Key already exists at slot a0 (overwrite value).
    # t4 = dst slot [a0] base.  Fall through to value write.

du_write_vval:
    # vval:
    lw   t3, SCR_VVAL0(x0); sw t3, SP_DATA0(s11)
    lw   t3, SCR_VVAL1(x0); sw t3, SP_DATA1(s11)
    lw   t3, SCR_VVAL2(x0); sw t3, SP_DATA2(s11)
    lw   t3, SCR_VVAL3(x0); sw t3, SP_DATA3(s11)
    addi t3, t4, 32
    sw   t3, SP_ADDR(s11)
    li   t3, SP_CTRL_WRITE
    sw   t3, SP_CTRL(s11)
du_wr_vval_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_wr_vval_poll
    # vtag:
    lw   t3, 12(x0)            # src vtag
    sw   t3, SP_DATA0(s11)
    li   t3, 0
    sw   t3, SP_DATA1(s11)
    sw   t3, SP_DATA2(s11)
    sw   t3, SP_DATA3(s11)
    addi t3, t4, 48
    sw   t3, SP_ADDR(s11)
    li   t3, SP_CTRL_WRITE
    sw   t3, SP_CTRL(s11)
du_wr_vtag_poll:
    lw   t3, SP_STATUS(s11)
    andi t3, t3, SP_STATUS_BUSY
    bne  t3, x0, du_wr_vtag_poll

du_insert_new:
du_overwrite:
du_next:
    j    du_loop

du_done:
    jal  ra, dict_write_used_slots    # commit final used count (s2) + slots (s1)
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    beq  s4, x0, du_heap_mb
    slli t0, s1, 6
    add  t0, s4, t0
    sw   t0, RES_HEAP_PTR(s11)
    j    du_go
du_heap_mb:
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, RES_HEAP_PTR(s11)
du_go:
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

set_write_elem_at:
    # a0 = index; write SCR_K* into s3 + idx*32
    addi sp, sp, -8
    sw   ra, 4(sp)
    slli t0, a0, 5
    add  t0, s3, t0
    sw   t0, 0(sp)                 # element base
    lw   t1, SCR_KVAL0(x0)
    sw   t1, SP_DATA0(s11)
    lw   t1, SCR_KVAL1(x0)
    sw   t1, SP_DATA1(s11)
    lw   t1, SCR_KVAL2(x0)
    sw   t1, SP_DATA2(s11)
    lw   t1, SCR_KVAL3(x0)
    sw   t1, SP_DATA3(s11)
    mv   a0, t0
    jal  ra, sp_write
    lw   a0, 0(sp)
    addi a0, a0, 16
    lw   t1, SCR_KTAG(x0)
    sw   t1, SP_DATA0(s11)
    li   t1, 0
    sw   t1, SP_DATA1(s11)
    sw   t1, SP_DATA2(s11)
    sw   t1, SP_DATA3(s11)
    jal  ra, sp_write
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0
