# list_grow.s -- excore firmware: LIST_* + DICT_* + SET_* trap handlers.
#
# Dispatch loop, parked until MB_STATUS.trap_pending is set. Handles
# PY_TRAP_LIST_GROW (9), LIST_EXTEND (10), DICT_GROW (11), LIST_DELETE (12),
# SET_GROW (13), SET_UPDATE (14), BUILTIN_CALL (16 / BI_PRINT console sink).
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
#   COMPLETED pop 3 for STORE_SUBSCR / STORE_NAME; pop 2 for STORE_ATTR (110).
#   INTENTIONALLY LEAKS the old table.
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
    .equ MB_INSTR_HI,    0x10
    .equ MB_HEAP_PTR,    0x14
    .equ MB_E0_VAL0,     0x20
    .equ MB_E0_VAL3,     0x2C
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
    .equ CONSOLE_TX,     0xF0

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
    .equ TRAP_BUILTIN_CALL,  16
    .equ TRAP_DICT_UPDATE,   19
    .equ TRAP_DICT_MERGE,    20

    # fatal_code values mirror pycore_defs.svh's PY_TRAP_* codes exactly --
    # Phase C forwards this 5-bit field (RES_CODE[8:4]) straight into
    # pycore_trap as a normal halt (see architecture.md's trap taxonomy).
    # do_fatal still uses slli-by-4; codes >= 16 occupy bit 8.
    .equ FATAL_TYPE,           1
    .equ FATAL_ILLEGAL_OPCODE, 5
    .equ FATAL_MEM_FAULT,      7

    .equ TAG_CONTROL,     0
    .equ TAG_INT,         1
    .equ TAG_FLOAT,       2
    .equ TAG_BOOL,        4
    .equ TAG_TUPLE,       6
    .equ TAG_SHORT_STR,   7
    .equ TAG_LONG_STR,    8
    .equ TAG_MUT_COLLEC,  9
    .equ TAG_OBJECT,     10
    .equ TAG_TOMBSTONE,  14

    # MUT_COLLEC kind is ENTRY value[127:124], i.e. VAL3[31:28].
    .equ MUT_LIST,        1
    .equ MUT_DICT,        2
    .equ MUT_SET,         3

    .equ OBK_BUILTIN,     4
    .equ BI_PRINT,        6
    .equ PY_CTL_NONE,     1

    # Mirror PYCORE_HEAP_LIMIT in pycore_defs.svh (frame stack at 0x1C000).
    .equ HEAP_LIMIT,     0x1C000

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
    .equ SCR_ORDER_PTR,  0x74
    .equ SCR_ORDER_LEN,  0x78
    .equ SCR_VERSION,    0x7C
    .equ SCR_NEW_ORDER,  0x80
    # DICT_UPDATE / DICT_MERGE source-dict walk scratch.
    .equ SCR_B_TABLE,    0x84
    .equ SCR_B_SLOTS,    0x88
    .equ SCR_B_IDX,      0x8C
    .equ SCR_C_OBJ,      0x90
    # 1 → dict_grow_rehash must NOT reload E1/E2 into scratch (bulk update).
    .equ SCR_KEEP,       0x94
    .equ SCR_NEED,       0x98
    # DICT_UPDATE / DICT_MERGE bulk-insert helper scratch.
    .equ SCR_DUPMODE,    0x9C
    .equ SCR_BULK_RA,    0xA0
    .equ SCR_USEDA,      0xA4
    .equ SCR_A_TABLE,    0xA8
    .equ SCR_A_SLOTS,    0xAC
    .equ SCR_BB_TABLE,   0xB0
    .equ SCR_BB_SLOTS,   0xB4
    .equ SCR_C_SLOTS,    0xB8
    .equ SCR_C_HEAP,     0xBC
    .equ SCR_ZIDX,       0xC0

reset:
    li   s11, MMIO_BASE            # s11: persistent MMIO base, never clobbered

wait_trap:
    lw   t0, MB_STATUS(s11)
    andi t0, t0, 1
    beq  t0, x0, wait_trap

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
    li   t1, TRAP_BUILTIN_CALL
    beq  t0, t1, tramp_builtin_call
    li   t1, TRAP_DICT_UPDATE
    beq  t0, t1, tramp_dict_update
    li   t1, TRAP_DICT_MERGE
    beq  t0, t1, tramp_dict_merge
    j    fatal_illegal

# J-type trampolines: handlers past B-type ±4KiB reach.
tramp_list_delete:
    j    do_list_delete
tramp_set_grow:
    j    do_set_grow
tramp_set_update:
    j    do_set_update
tramp_builtin_call:
    j    do_builtin_call
tramp_dict_update:
    j    do_dict_update
tramp_dict_merge:
    j    do_dict_merge

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
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_LIST
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
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_LIST
    bne  t0, t1, fatal_type
    lw   s0, MB_E0_VAL0(s11)       # s0 = dst obj_addr

    lw   s9, MB_E1_TAG(s11)        # s9 = src tag
    li   t1, TAG_MUT_COLLEC
    bne  s9, t1, ext_src_tuple_check
    lw   t0, MB_E1_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_LIST
    bne  t0, t1, fatal_type
    j    ext_src_ok
ext_src_tuple_check:
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
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_DICT
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
    # STORE_ATTR (opcode 110): value+obj on stack → pop 2. MAP_ADD (opcode 98):
    # key+value popped, dict left in place → pop 2. Else STORE_SUBSCR
    # (value+key+container) / STORE_NAME → pop 3.
    lw   t0, MB_INSTR_LO(s11)
    andi t0, t0, 0xFF
    li   t1, 110
    beq  t0, t1, dg_pop_store_attr
    li   t1, 98
    beq  t0, t1, dg_pop_store_attr
    li   t0, 3
    j    dg_pop_store
dg_pop_store_attr:
    li   t0, 2
dg_pop_store:
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
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_LIST
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

# → s1=slots, s2=used, s5/s3=table; order metadata in SCR_ORDER_*
dict_load_header_table:
    sw   ra, SCR_RA(x0)
    mv   a0, s0
    jal  ra, sp_read
    lw   s2, SP_DATA0(s11)
    lw   s1, SP_DATA2(s11)
    addi a0, s0, 16
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_ORDER_LEN(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_VERSION(x0)
    addi a0, s0, 32
    jal  ra, sp_read
    lw   s5, SP_DATA0(s11)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_ORDER_PTR(x0)
    mv   s3, s5
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

# SET retains the v2 two-word object layout:
#   obj+0={slots,used}, obj+16={0,table_ptr}.
# Keep this separate from DICT v3 metadata/order-pointer loading.
set_load_header_table:
    sw   ra, SCR_RA(x0)
    mv   a0, s0
    jal  ra, sp_read
    lw   s2, SP_DATA0(s11)
    lw   s1, SP_DATA2(s11)
    addi a0, s0, 16
    jal  ra, sp_read
    lw   s5, SP_DATA0(s11)
    mv   s3, s5
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

dict_write_used_slots:
    sw   ra, SCR_RA3(x0)
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    lw   ra, SCR_RA3(x0)
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

# grow+rehash: s1/s2/s5 → s4/s7/s3=new table.
#   dict_grow_rehash:      reloads E1/E2 into scratch afterward (STORE_SUBSCR /
#                          STORE_ATTR / MAP_ADD single-insert path).
#   dict_grow_rehash_keep: leaves SCR_K*/SCR_V* untouched so a bulk-insert
#                          caller (DICT_UPDATE) keeps its own walk state.
dict_grow_rehash_keep:
    li   t0, 1
    sw   t0, SCR_KEEP(x0)
    j    dgr_entry
dict_grow_rehash:
    sw   x0, SCR_KEEP(x0)
dgr_entry:
    sw   ra, SCR_RA(x0)
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
    lw   t3, MB_HEAP_PTR(s11)
    sw   t3, SCR_NEW_ORDER(x0)
    slli t0, s7, 5
    add  s4, t3, t0              # table follows new order buffer
    slli t0, s7, 6
    add  t0, s4, t0
    li   t1, HEAP_LIMIT
    bge  t1, t0, dgr_copy_order
    j    fatal_mem
dgr_copy_order:
    li   s6, 0
dgr_copy_order_loop:
    lw   t0, SCR_ORDER_LEN(x0)
    beq  s6, t0, dgr_zero
    lw   t1, SCR_ORDER_PTR(x0)
    slli t2, s6, 5
    add  a0, t1, t2
    jal  ra, sp_read
    lw   t3, SP_DATA0(s11)
    lw   t4, SP_DATA1(s11)
    lw   t5, SP_DATA2(s11)
    lw   t6, SP_DATA3(s11)
    lw   t1, SCR_NEW_ORDER(x0)
    slli t2, s6, 5
    add  a0, t1, t2
    sw   t3, SP_DATA0(s11)
    sw   t4, SP_DATA1(s11)
    sw   t5, SP_DATA2(s11)
    sw   t6, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t1, SCR_ORDER_PTR(x0)
    slli t2, s6, 5
    add  a0, t1, t2
    addi a0, a0, 16
    jal  ra, sp_read
    lw   t3, SP_DATA0(s11)
    lw   t1, SCR_NEW_ORDER(x0)
    slli t2, s6, 5
    add  a0, t1, t2
    addi a0, a0, 16
    sw   t3, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   t0, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    addi s6, s6, 1
    j    dgr_copy_order_loop
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
    lw   t0, SCR_KEEP(x0)
    bne  t0, x0, dgr_skip_reload
    jal  ra, load_e1e2_to_scratch
dgr_skip_reload:
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

dict_insert_from_scratch:
    sw   ra, SCR_RA(x0)
    sw   s1, SCR_A1(x0)
    mv   s1, s7
    jal  ra, dict_probe
    lw   s1, SCR_A1(x0)
    lw   t0, SCR_FOUND(x0)
    bne  t0, x0, difs_over
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_kv_at
    addi s2, s2, 1
    # Append the new key to the preserved insertion-order sidecar.
    lw   t0, SCR_ORDER_LEN(x0)
    lw   t1, SCR_NEW_ORDER(x0)
    slli t2, t0, 5
    add  a0, t1, t2
    lw   t3, SCR_KVAL0(x0)
    sw   t3, SP_DATA0(s11)
    lw   t3, SCR_KVAL1(x0)
    sw   t3, SP_DATA1(s11)
    lw   t3, SCR_KVAL2(x0)
    sw   t3, SP_DATA2(s11)
    lw   t3, SCR_KVAL3(x0)
    sw   t3, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t0, SCR_ORDER_LEN(x0)
    lw   t1, SCR_NEW_ORDER(x0)
    slli t2, t0, 5
    add  a0, t1, t2
    addi a0, a0, 16
    lw   t3, SCR_KTAG(x0)
    sw   t3, SP_DATA0(s11)
    li   t4, 0
    sw   t4, SP_DATA1(s11)
    sw   t4, SP_DATA2(s11)
    sw   t4, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t0, SCR_ORDER_LEN(x0)
    addi t0, t0, 1
    sw   t0, SCR_ORDER_LEN(x0)
    lw   t0, SCR_VERSION(x0)
    addi t0, t0, 1
    sw   t0, SCR_VERSION(x0)
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0
difs_over:
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_val_at
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

dict_writeback_header:
    sw   ra, SCR_RA(x0)
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s7, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    lw   t0, SCR_ORDER_LEN(x0)
    sw   t0, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    lw   t0, SCR_VERSION(x0)
    sw   t0, SP_DATA2(s11)
    li   t0, 0
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    addi a0, s0, 32
    sw   s4, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    lw   t1, SCR_NEW_ORDER(x0)
    sw   t1, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    mv   s1, s7
    mv   s3, s4
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

# probe s3/s1 with SCR_K* → SCR_FOUND / SCR_IDX / SCR_TOMB
dict_probe:
    sw   ra, SCR_RA2(x0)
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
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0
dprobe_hit:
    li   t0, 1
    sw   t0, SCR_FOUND(x0)
    lw   ra, SCR_RA2(x0)
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
    sw   ra, SCR_RA3(x0)
    sw   a0, SCR_A0(x0)
    slli t0, a0, 6
    add  t2, s3, t0
    sw   t2, SCR_A1(x0)
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
    lw   a0, SCR_A0(x0)
    jal  ra, dict_write_val_at
    lw   ra, SCR_RA3(x0)
    jalr x0, ra, 0

dict_write_val_at:
    sw   ra, SCR_FTI0(x0)
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
    lw   ra, SCR_FTI0(x0)
    jalr x0, ra, 0

dict_read_val_to_res:
    sw   ra, SCR_RA3(x0)
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
    lw   ra, SCR_RA3(x0)
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
    sw   ra, SCR_RA3(x0)
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
    lw   ra, SCR_RA3(x0)
    jalr x0, ra, 0

# keys_rich_eq: SCR_K* vs SCR_SK* → a0
keys_rich_eq:
    sw   ra, SCR_A0(x0)
    lw   a2, SCR_KTAG(x0)
    lw   a3, SCR_SKTAG(x0)
    mv   a4, a2
    lw   t3, SCR_KVAL0(x0)
    lw   t4, SCR_KVAL1(x0)
    jal  ra, norm_numeric
    beq  a0, x0, kreq_bits
    sw   a1, SCR_A1(x0)
    sw   t3, SCR_TMP_L0(x0)
    sw   t4, SCR_TMP_L1(x0)
    mv   a4, a3
    lw   t3, SCR_SKVAL0(x0)
    lw   t4, SCR_SKVAL1(x0)
    jal  ra, norm_numeric
    beq  a0, x0, kreq_bits
    lw   t0, SCR_A1(x0)
    bne  t0, x0, kreq_fb
    bne  a1, x0, kreq_fb
    lw   t5, SCR_TMP_L0(x0)
    lw   t6, SCR_TMP_L1(x0)
    bne  t3, t5, kreq_no
    bne  t4, t6, kreq_no
    li   a0, 1
    lw   ra, SCR_A0(x0)
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
    lw   ra, SCR_A0(x0)
    jalr x0, ra, 0
kreq_no:
    li   a0, 0
    lw   ra, SCR_A0(x0)
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
    sw   ra, SCR_RA3(x0)
    jal  ra, float_to_int
    lw   ra, SCR_RA3(x0)
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
    li   t1, TAG_MUT_COLLEC
    beq  t0, t1, sg_primary_ok
    j    fatal_type
sg_primary_ok:
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_SET
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
    jal  ra, set_load_header_table    # s1=slots, s2=used, s5/s3=table
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
    li   t1, TAG_MUT_COLLEC
    beq  t0, t1, su_primary_ok
    j    fatal_type
su_primary_ok:
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_SET
    beq  t0, t1, su_tag_ok
    j    fatal_type
su_tag_ok:
    lw   s0, MB_E0_VAL0(s11)
    jal  ra, set_load_header_table
    lw   s9, MB_E1_TAG(s11)
    lw   s10, MB_E1_VAL0(s11)
    li   t1, TAG_MUT_COLLEC
    bne  s9, t1, su_src_tuple_check
    lw   t0, MB_E1_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_LIST
    beq  t0, t1, su_src_list
    li   t1, MUT_SET
    beq  t0, t1, su_src_set
    li   t1, MUT_DICT
    beq  t0, t1, su_src_dict
    j    fatal_type
su_src_tuple_check:
    li   t1, TAG_TUPLE
    beq  s9, t1, su_src_tuple
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

# DICT source (SET_UPDATE from dict): insert the dict's KEYS into the set.
# Walk the dict table (stride 64); the key lives at slot+0 (val) / slot+16
# (tag), matching v3 dict layout.
su_src_dict:
    mv   a0, s10
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)         # used(dict) → grow sizing upper bound
    sw   t0, SCR_TMP_L1(x0)
    lw   t1, SP_DATA2(s11)         # slots(dict) → walk count
    sw   t1, SCR_TMP_L0(x0)
    addi a0, s10, 32              # dict pointers: table_ptr at word0
    jal  ra, sp_read
    lw   s8, SP_DATA0(s11)
    li   s9, 2
    lw   t0, SCR_TMP_L1(x0)
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
    li   t1, 2
    beq  s9, t1, su_load_dict
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
    j    su_insert
# DICT source key loader: stride 64, key val at slot+0, key tag at slot+16.
su_load_dict:
    slli t0, s6, 6
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
    sw   ra, SCR_RA(x0)
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
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

set_writeback_header:
    # alias: header already written in set_grow_rehash; bump used after insert
    sw   ra, SCR_RA(x0)
    jal  ra, dict_write_used_slots
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

set_insert_from_scratch:
    sw   ra, SCR_RA(x0)
    jal  ra, set_probe
    lw   t0, SCR_FOUND(x0)
    bne  t0, x0, sifs_done
    lw   a0, SCR_IDX(x0)
    jal  ra, set_write_elem_at
    addi s2, s2, 1
sifs_done:
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

# set_probe: like dict_probe but stride 32
set_probe:
    sw   ra, SCR_RA2(x0)
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
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0
sprobe_hit:
    li   t0, 1
    sw   t0, SCR_FOUND(x0)
    lw   ra, SCR_RA2(x0)
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

set_write_elem_at:
    # a0 = index; write SCR_K* into s3 + idx*32
    sw   ra, SCR_RA3(x0)
    slli t0, a0, 5
    add  t0, s3, t0
    sw   t0, SCR_A0(x0)            # element base
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
    lw   a0, SCR_A0(x0)
    addi a0, a0, 16
    lw   t1, SCR_KTAG(x0)
    sw   t1, SP_DATA0(s11)
    li   t1, 0
    sw   t1, SP_DATA1(s11)
    sw   t1, SP_DATA2(s11)
    sw   t1, SP_DATA3(s11)
    jal  ra, sp_write
    lw   ra, SCR_RA3(x0)
    jalr x0, ra, 0

# ===========================================================================
# DICT_UPDATE (trap 19): E0 = dest dict A, E1 = source dict B.
# Grow A to fit used(A)+used(B), then insert every entry of B into A,
# overwriting duplicate keys. A is mutated in place (its handle/RF slot is
# unchanged); COMPLETED pop 1 (source), push 0.
# ===========================================================================
do_dict_update:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_DICT
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E1_TAG(s11)
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E1_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_DICT
    bne  t0, t1, xd_fatal_type
    lw   s0, MB_E0_VAL0(s11)
    jal  ra, dict_load_header_table   # s1=slotsA s2=usedA s5=s3=tableA order*
    lw   s9, MB_E1_VAL0(s11)
    mv   a0, s9
    jal  ra, sp_read
    lw   s10, SP_DATA0(s11)            # usedB
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_B_SLOTS(x0)           # slotsB = walk count
    addi a0, s9, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_B_TABLE(x0)           # tableB = walk source
    add  a0, s2, s10                   # need = usedA + usedB
    sw   a0, SCR_NEED(x0)
    mv   a1, s1
    jal  ra, dict_needs_grow
    beq  a0, x0, du_no_grow
    lw   s2, SCR_NEED(x0)              # size the new table for the union
    jal  ra, dict_grow_rehash_keep
    mv   s1, s7                        # slots = new
    mv   s3, s4                        # table = new
    lw   t0, SCR_NEW_ORDER(x0)
    sw   t0, SCR_ORDER_PTR(x0)         # order buffer = new
    lw   t0, SCR_NEED(x0)
    sub  s2, t0, s10                   # restore usedA
    slli t0, s7, 6
    add  t0, s4, t0
    sw   t0, SCR_C_HEAP(x0)            # new heap = table + slots*64
    j    du_insert
du_no_grow:
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, SCR_C_HEAP(x0)
du_insert:
    sw   x0, SCR_DUPMODE(x0)           # overwrite duplicate keys
    jal  ra, dict_bulk_insert
    jal  ra, dict_writeback_all
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 1
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 0
    sw   t0, RES_PUSH_COUNT(s11)
    lw   t0, SCR_C_HEAP(x0)
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ===========================================================================
# DICT_MERGE (trap 20): E0 = dict A, E1 = dict B. Build a fresh dict C sized
# for used(A)+used(B); insert A then B. A key present in both A and B is a
# duplicate keyword → FATAL(TYPE). COMPLETED pop 2, push 1 (C in RES_E0),
# landing C where A was (DICT_MERGE oparg == 1).
# ===========================================================================
do_dict_merge:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E0_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_DICT
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E1_TAG(s11)
    li   t1, TAG_MUT_COLLEC
    bne  t0, t1, xd_fatal_type
    lw   t0, MB_E1_VAL3(s11)
    srli t0, t0, 28
    li   t1, MUT_DICT
    bne  t0, t1, xd_fatal_type
    lw   s0, MB_E0_VAL0(s11)           # A addr (temp)
    lw   s9, MB_E1_VAL0(s11)           # B addr
    mv   a0, s0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)             # usedA
    sw   t0, SCR_USEDA(x0)
    lw   t0, SP_DATA2(s11)             # slotsA
    sw   t0, SCR_A_SLOTS(x0)
    addi a0, s0, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)             # tableA
    sw   t0, SCR_A_TABLE(x0)
    mv   a0, s9
    jal  ra, sp_read
    lw   s10, SP_DATA0(s11)            # usedB
    lw   t0, SP_DATA2(s11)             # slotsB
    sw   t0, SCR_BB_SLOTS(x0)
    addi a0, s9, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)             # tableB
    sw   t0, SCR_BB_TABLE(x0)
    lw   t0, SCR_USEDA(x0)
    add  a0, t0, s10                   # need = usedA + usedB
    jal  ra, dict_calc_slots          # a0 = C slots
    sw   a0, SCR_C_SLOTS(x0)
    lw   s0, MB_HEAP_PTR(s11)          # s0 = C obj
    addi t0, s0, 48
    sw   t0, SCR_ORDER_PTR(x0)         # C order at C+48
    lw   t1, SCR_C_SLOTS(x0)
    slli t2, t1, 5
    add  t3, t0, t2                    # C table = C+48+slots*32
    mv   s3, t3
    slli t2, t1, 6
    add  t4, t3, t2                    # new heap = table + slots*64
    li   t5, HEAP_LIMIT
    blt  t5, t4, xd_fatal_mem
    sw   t4, SCR_C_HEAP(x0)
    mv   s1, t1                        # C slots
    li   s2, 0                         # C used
    sw   x0, SCR_ORDER_LEN(x0)
    sw   x0, SCR_VERSION(x0)
    sw   x0, SCR_ZIDX(x0)
dm_zero:
    lw   t0, SCR_ZIDX(x0)
    lw   t1, SCR_C_SLOTS(x0)
    beq  t0, t1, dm_zdone
    slli t2, t0, 6
    add  a0, s3, t2
    addi a0, a0, 16                    # zero each slot's ktag (empty marker)
    li   t3, 0
    sw   t3, SP_DATA0(s11)
    sw   t3, SP_DATA1(s11)
    sw   t3, SP_DATA2(s11)
    sw   t3, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t0, SCR_ZIDX(x0)
    addi t0, t0, 1
    sw   t0, SCR_ZIDX(x0)
    j    dm_zero
dm_zdone:
    lw   t0, SCR_A_TABLE(x0)           # walk A into C
    sw   t0, SCR_B_TABLE(x0)
    lw   t0, SCR_A_SLOTS(x0)
    sw   t0, SCR_B_SLOTS(x0)
    sw   x0, SCR_DUPMODE(x0)
    jal  ra, dict_bulk_insert
    lw   t0, SCR_BB_TABLE(x0)          # walk B into C (dup key → fatal)
    sw   t0, SCR_B_TABLE(x0)
    lw   t0, SCR_BB_SLOTS(x0)
    sw   t0, SCR_B_SLOTS(x0)
    li   t0, 1
    sw   t0, SCR_DUPMODE(x0)
    jal  ra, dict_bulk_insert
    jal  ra, dict_writeback_all
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 2
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 1
    sw   t0, RES_PUSH_COUNT(s11)
    lw   t0, SCR_C_HEAP(x0)
    sw   t0, RES_HEAP_PTR(s11)
    sw   s0, RES_E0_VAL0(s11)
    li   t0, 0
    sw   t0, RES_E0_VAL1(s11)
    sw   t0, RES_E0_VAL2(s11)
    li   t0, 0x20000000               # MUT_DICT kind (2) at value[127:124]
    sw   t0, RES_E0_VAL3(s11)
    li   t0, TAG_MUT_COLLEC
    sw   t0, RES_E0_TAG(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# dict_bulk_insert: walk SCR_B_TABLE[0..SCR_B_SLOTS) (stride 64) and insert
# each live (key,value) into the destination dict held in s0/s1/s2/s3 +
# SCR_ORDER_PTR/SCR_ORDER_LEN/SCR_VERSION. SCR_DUPMODE selects behavior on an
# existing key: 0 = overwrite value (update); 1 = FATAL(TYPE) (merge dup kwarg).
# The destination must be pre-sized to hold every insert (open addressing needs
# a spare slot). Updates s2 (used) plus the order sidecar / version per new key.
dict_bulk_insert:
    sw   ra, SCR_BULK_RA(x0)
    sw   x0, SCR_B_IDX(x0)
dbi_loop:
    lw   t0, SCR_B_IDX(x0)
    lw   t1, SCR_B_SLOTS(x0)
    bgeu t0, t1, dbi_done
    lw   t2, SCR_B_TABLE(x0)
    slli t3, t0, 6
    add  t4, t2, t3
    addi a0, t4, 16                    # ktag
    jal  ra, sp_read
    lw   a1, SP_DATA0(s11)
    beq  a1, x0, dbi_next
    li   t0, TAG_TOMBSTONE
    beq  a1, t0, dbi_next
    lw   t0, SCR_B_IDX(x0)             # key value at slot+0
    lw   t2, SCR_B_TABLE(x0)
    slli t3, t0, 6
    add  t4, t2, t3
    mv   a0, t4
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_KVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_KVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_KVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_KVAL3(x0)
    lw   t0, SCR_B_IDX(x0)             # key tag at slot+16
    lw   t2, SCR_B_TABLE(x0)
    slli t3, t0, 6
    add  t4, t2, t3
    addi a0, t4, 16
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_KTAG(x0)
    lw   t0, SCR_B_IDX(x0)             # value at slot+32
    lw   t2, SCR_B_TABLE(x0)
    slli t3, t0, 6
    add  t4, t2, t3
    addi a0, t4, 32
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_VVAL0(x0)
    lw   t0, SP_DATA1(s11)
    sw   t0, SCR_VVAL1(x0)
    lw   t0, SP_DATA2(s11)
    sw   t0, SCR_VVAL2(x0)
    lw   t0, SP_DATA3(s11)
    sw   t0, SCR_VVAL3(x0)
    lw   t0, SCR_B_IDX(x0)             # value tag at slot+48
    lw   t2, SCR_B_TABLE(x0)
    slli t3, t0, 6
    add  t4, t2, t3
    addi a0, t4, 48
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SCR_VTAG(x0)
    jal  ra, dict_probe               # dest s3/s1 + SCR_K → SCR_FOUND/SCR_IDX
    lw   t0, SCR_FOUND(x0)
    beq  t0, x0, dbi_insert
    lw   t0, SCR_DUPMODE(x0)
    bne  t0, x0, dbi_dup
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_val_at
    j    dbi_next
dbi_dup:
    j    fatal_type
dbi_insert:
    lw   a0, SCR_IDX(x0)
    jal  ra, dict_write_kv_at
    addi s2, s2, 1
    lw   t0, SCR_ORDER_LEN(x0)         # append key to insertion-order sidecar
    lw   t1, SCR_ORDER_PTR(x0)
    slli t2, t0, 5
    add  a0, t1, t2
    lw   t3, SCR_KVAL0(x0)
    sw   t3, SP_DATA0(s11)
    lw   t3, SCR_KVAL1(x0)
    sw   t3, SP_DATA1(s11)
    lw   t3, SCR_KVAL2(x0)
    sw   t3, SP_DATA2(s11)
    lw   t3, SCR_KVAL3(x0)
    sw   t3, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t0, SCR_ORDER_LEN(x0)
    lw   t1, SCR_ORDER_PTR(x0)
    slli t2, t0, 5
    add  a0, t1, t2
    addi a0, a0, 16
    lw   t3, SCR_KTAG(x0)
    sw   t3, SP_DATA0(s11)
    li   t4, 0
    sw   t4, SP_DATA1(s11)
    sw   t4, SP_DATA2(s11)
    sw   t4, SP_DATA3(s11)
    jal  ra, sp_write
    lw   t0, SCR_ORDER_LEN(x0)
    addi t0, t0, 1
    sw   t0, SCR_ORDER_LEN(x0)
    lw   t0, SCR_VERSION(x0)
    addi t0, t0, 1
    sw   t0, SCR_VERSION(x0)
dbi_next:
    lw   t0, SCR_B_IDX(x0)
    addi t0, t0, 1
    sw   t0, SCR_B_IDX(x0)
    j    dbi_loop
dbi_done:
    lw   ra, SCR_BULK_RA(x0)
    jalr x0, ra, 0

# dict_calc_slots(a0 = target used) → a0 = pow2 slot count. Mirrors
# dict_grow_rehash sizing: 4x (used < 50000) or 2x, min 8, strictly > target.
dict_calc_slots:
    li   t0, 50000
    bltu t0, a0, dcs_mul2
    slli t1, a0, 2
    j    dcs_min
dcs_mul2:
    slli t1, a0, 1
dcs_min:
    li   t0, 8
    bge  t1, t0, dcs_p2i
    li   t1, 8
dcs_p2i:
    li   t2, 8
dcs_p2:
    bge  t2, t1, dcs_gt
    slli t2, t2, 1
    j    dcs_p2
dcs_gt:
    blt  a0, t2, dcs_ret
    slli t2, t2, 1
    j    dcs_gt
dcs_ret:
    mv   a0, t2
    jalr x0, ra, 0

# dict_writeback_all: publish dest header/meta/pointers from
# s0/s1/s2/s3 + SCR_ORDER_PTR/SCR_ORDER_LEN/SCR_VERSION.
dict_writeback_all:
    sw   ra, SCR_RA(x0)
    sw   s2, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)
    sw   t0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    lw   t0, SCR_ORDER_LEN(x0)
    sw   t0, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    lw   t0, SCR_VERSION(x0)
    sw   t0, SP_DATA2(s11)
    li   t0, 0
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    addi a0, s0, 32
    sw   s3, SP_DATA0(s11)
    li   t0, 0
    sw   t0, SP_DATA1(s11)
    lw   t0, SCR_ORDER_PTR(x0)
    sw   t0, SP_DATA2(s11)
    li   t0, 0
    sw   t0, SP_DATA3(s11)
    jal  ra, sp_write
    lw   ra, SCR_RA(x0)
    jalr x0, ra, 0

# B-type-reachable fatal trampolines for the dict update/merge block.
xd_fatal_type:
    j    fatal_type
xd_fatal_mem:
    j    fatal_mem

# ===========================================================================
# BUILTIN_CALL (trap 16): OBK_BUILTIN / BI_PRINT one-argument console sink.
# ===========================================================================
do_builtin_call:
    lw   t0, MB_E0_TAG(s11)
    li   t1, TAG_OBJECT
    bne  t0, t1, bi_fatal_illegal
    lw   s0, MB_E0_VAL0(s11)       # s0 = builtin object addr

    # ob_head at obj+0: kind lives in value[127:96] => SP_DATA3.
    mv   a0, s0
    jal  ra, sp_read
    lw   t0, SP_DATA3(s11)
    li   t1, OBK_BUILTIN
    bne  t0, t1, bi_fatal_illegal

    # field0 is builtin_id: value at obj+32, tag at obj+48.
    addi a0, s0, 32
    jal  ra, sp_read
    lw   s1, SP_DATA0(s11)         # builtin_id low word
    addi a0, s0, 48
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    li   t1, TAG_INT
    bne  t0, t1, bi_fatal_illegal
    li   t1, BI_PRINT
    bne  s1, t1, bi_fatal_illegal
    j    do_bi_print

do_bi_print:
    # CALL oparg is argc: arg = (MB_INSTR_LO >> 8) | (MB_INSTR_HI << 24).
    lw   t0, MB_INSTR_LO(s11)
    srli t0, t0, 8
    lw   t1, MB_INSTR_HI(s11)
    slli t1, t1, 24
    or   t0, t0, t1
    slli t0, t0, 16
    srli t0, t0, 16                # argc low 16 bits
    li   t1, 1
    bne  t0, t1, bi_fatal_type

    lw   t0, MB_E2_TAG(s11)
    li   t1, TAG_SHORT_STR
    beq  t0, t1, bi_print_short_str
    li   t1, TAG_INT
    beq  t0, t1, bi_print_int
    li   t1, TAG_BOOL
    beq  t0, t1, bi_print_bool
    li   t1, TAG_CONTROL
    beq  t0, t1, bi_print_control
    li   t1, TAG_LONG_STR
    beq  t0, t1, bi_print_long_str
    j    bi_fatal_type

bi_print_short_str:
    lw   t0, MB_E2_VAL0(s11)
    sw   t0, SCR_VVAL0(x0)
    lw   t0, MB_E2_VAL1(s11)
    sw   t0, SCR_VVAL1(x0)
    lw   t0, MB_E2_VAL2(s11)
    sw   t0, SCR_VVAL2(x0)
    lw   t0, MB_E2_VAL3(s11)
    sw   t0, SCR_VVAL3(x0)
    jal  ra, emit_short_str
    j    bi_print_completed

bi_print_int:
    lw   a0, MB_E2_VAL0(s11)
    jal  ra, emit_int
    j    bi_print_completed

bi_print_bool:
    lw   t0, MB_E2_VAL0(s11)
    beq  t0, x0, bi_print_false
    jal  ra, emit_true
    j    bi_print_completed
bi_print_false:
    jal  ra, emit_false
    j    bi_print_completed

bi_print_control:
    lw   t0, MB_E2_VAL0(s11)
    li   t1, PY_CTL_NONE
    bne  t0, t1, bi_fatal_type
    jal  ra, emit_none
    j    bi_print_completed

bi_print_long_str:
    # Phase 2 will stream LONG_STR via string_mem or a ROM character loop.
    j    bi_fatal_type

bi_print_completed:
    li   t0, RES_COMPLETED
    sw   t0, RES_CODE(s11)
    li   t0, 3                     # callable + NULL/bound-self + arg0
    sw   t0, RES_POP_COUNT(s11)
    li   t0, 1
    sw   t0, RES_PUSH_COUNT(s11)
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, RES_HEAP_PTR(s11)
    li   t0, PY_CTL_NONE
    sw   t0, RES_E0_VAL0(s11)
    sw   x0, RES_E0_VAL1(s11)
    sw   x0, RES_E0_VAL2(s11)
    sw   x0, RES_E0_VAL3(s11)
    li   t0, TAG_CONTROL
    sw   t0, RES_E0_TAG(s11)
    li   t0, 1
    sw   t0, RES_GO(s11)
    j    wait_trap

# ---- BI_PRINT emit helpers -------------------------------------------------

emit_byte:
    sw   a0, CONSOLE_TX(s11)
    jalr x0, ra, 0

emit_true:
    sw   ra, SCR_RA2(x0)
    li   a0, 84                    # T
    jal  ra, emit_byte
    li   a0, 114                   # r
    jal  ra, emit_byte
    li   a0, 117                   # u
    jal  ra, emit_byte
    li   a0, 101                   # e
    jal  ra, emit_byte
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0

emit_false:
    sw   ra, SCR_RA2(x0)
    li   a0, 70                    # F
    jal  ra, emit_byte
    li   a0, 97                    # a
    jal  ra, emit_byte
    li   a0, 108                   # l
    jal  ra, emit_byte
    li   a0, 115                   # s
    jal  ra, emit_byte
    li   a0, 101                   # e
    jal  ra, emit_byte
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0

emit_none:
    sw   ra, SCR_RA2(x0)
    li   a0, 78                    # N
    jal  ra, emit_byte
    li   a0, 111                   # o
    jal  ra, emit_byte
    li   a0, 110                   # n
    jal  ra, emit_byte
    li   a0, 101                   # e
    jal  ra, emit_byte
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0

emit_short_str:
    sw   ra, SCR_RA2(x0)
    lw   t0, SCR_VVAL3(x0)
    srli s0, t0, 28                # remaining byte count
    beq  s0, x0, ess_done
    srli a0, t0, 20
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t0, 12
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t0, 4
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    andi t1, t0, 15
    slli t1, t1, 4
    lw   t2, SCR_VVAL2(x0)
    srli a0, t2, 28
    or   a0, a0, t1
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 20
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 12
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 4
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    andi t1, t2, 15
    slli t1, t1, 4
    lw   t0, SCR_VVAL1(x0)
    srli a0, t0, 28
    or   a0, a0, t1
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t0, 20
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t0, 12
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t0, 4
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    andi t1, t0, 15
    slli t1, t1, 4
    lw   t2, SCR_VVAL0(x0)
    srli a0, t2, 28
    or   a0, a0, t1
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 20
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 12
    andi a0, a0, 255
    jal  ra, emit_byte
    addi s0, s0, -1
    beq  s0, x0, ess_done
    srli a0, t2, 4
    andi a0, a0, 255
    jal  ra, emit_byte
ess_done:
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0

emit_int:
    sw   ra, SCR_RA2(x0)
    mv   t3, a0                    # unsigned magnitude after sign handling
    bne  t3, x0, ei_nonzero
    li   a0, 48                    # 0
    jal  ra, emit_byte
    j    ei_done
ei_nonzero:
    li   s1, 0                     # have emitted a non-leading digit
    bge  t3, x0, ei_digits
    li   a0, 45                    # -
    jal  ra, emit_byte
    sub  t3, x0, t3
ei_digits:
    li   a0, 1000000000
    jal  ra, emit_int_digit
    li   a0, 100000000
    jal  ra, emit_int_digit
    li   a0, 10000000
    jal  ra, emit_int_digit
    li   a0, 1000000
    jal  ra, emit_int_digit
    li   a0, 100000
    jal  ra, emit_int_digit
    li   a0, 10000
    jal  ra, emit_int_digit
    li   a0, 1000
    jal  ra, emit_int_digit
    li   a0, 100
    jal  ra, emit_int_digit
    li   a0, 10
    jal  ra, emit_int_digit
    li   a0, 1
    jal  ra, emit_int_digit
ei_done:
    lw   ra, SCR_RA2(x0)
    jalr x0, ra, 0

emit_int_digit:
    li   t4, 0                     # digit for current power of ten
eid_sub_loop:
    bltu t3, a0, eid_counted
    sub  t3, t3, a0
    addi t4, t4, 1
    j    eid_sub_loop
eid_counted:
    bne  s1, x0, eid_emit
    bne  t4, x0, eid_start
    li   t5, 1
    bne  a0, t5, eid_ret
eid_start:
    li   s1, 1
eid_emit:
    sw   ra, SCR_RA3(x0)
    addi a0, t4, 48
    jal  ra, emit_byte
    lw   ra, SCR_RA3(x0)
eid_ret:
    jalr x0, ra, 0

bi_fatal_type:
    j    fatal_type
bi_fatal_illegal:
    j    fatal_illegal
