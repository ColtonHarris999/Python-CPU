# mm.s — excore firmware memory manager (appended after list_grow.s).
#
# Metadata in reserved dmem below the heap (see PYCORE_MM_* in pycore_defs.svh):
#   MM_BASE+0x00  magic ("MM01")
#   MM_BASE+0x10  wilderness pointer
#   MM_BASE+0x20  size-class free-list heads (8 × 16B)
#   MM_BASE+0xA0  general free-list head
#
# Allocated: hdr { size, MM_ALLOC_MAGIC } + payload (returned addr = hdr+16)
# Free:      hdr { next, size } + { MM_FREE_MAGIC, 0 }
#
# ABI:
#   mm_alloc(a0=req_bytes, a1=unused, a2=header_kind)
#     → a0=status(0/1), a1=payload_size, a2=payload_ptr
#   mm_free(a0=payload_ptr)  — no-op if alloc magic missing (pre-MM buffer)
#   mm_ensure_init / mm_wilderness_get / mm_wilderness_set
# header_kind: 0=NONE 1=LIST 2=DICT 3=SET

    .equ MM_BASE,          0x0200
    .equ MM_WILD_OFF,      0x10
    .equ MM_HEADS_OFF,     0x20
    .equ MM_GEN_OFF,       0xA0
    .equ MM_INIT_MAGIC,    0x4D4D3031
    .equ MM_ALLOC_MAGIC,   0xA110CA7E
    .equ MM_FREE_MAGIC,    0xF2EEF2EE
    .equ MM_HDR_BYTES,     16
    .equ MM_HK_NONE,       0
    .equ MM_HK_LIST,       1
    .equ MM_HK_DICT,       2
    .equ MM_HK_SET,        3

# ===========================================================================
mm_ensure_init:
    addi sp, sp, -8
    sw   ra, 4(sp)
    sw   s0, 0(sp)
    li   a0, MM_BASE
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    li   t1, MM_INIT_MAGIC
    beq  t0, t1, mmei_done
    li   t0, MM_INIT_MAGIC
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, MM_BASE
    jal  ra, sp_write
    lw   t0, MB_HEAP_PTR(s11)
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, MM_BASE
    addi a0, a0, MM_WILD_OFF
    jal  ra, sp_write
    li   s0, 0
mmei_zh:
    li   t0, 9
    beq  s0, t0, mmei_done
    slli t0, s0, 4
    li   a0, MM_BASE
    addi a0, a0, MM_HEADS_OFF
    add  a0, a0, t0
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    jal  ra, sp_write
    addi s0, s0, 1
    j    mmei_zh
mmei_done:
    # Sync wilderness forward if pycore bumped past us (MB_HEAP_PTR > wild).
    li   a0, MM_BASE
    addi a0, a0, MM_WILD_OFF
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    lw   t1, MB_HEAP_PTR(s11)
    bgeu t0, t1, mmei_synced
    sw   t1, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, MM_BASE
    addi a0, a0, MM_WILD_OFF
    jal  ra, sp_write
mmei_synced:
    lw   s0, 0(sp)
    lw   ra, 4(sp)
    addi sp, sp, 8
    jalr x0, ra, 0

mm_wilderness_get:
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, mm_ensure_init
    li   a0, MM_BASE
    addi a0, a0, MM_WILD_OFF
    jal  ra, sp_read
    lw   a0, SP_DATA0(s11)
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

mm_wilderness_set:
    addi sp, sp, -4
    sw   ra, 0(sp)
    sw   a0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, MM_BASE
    addi a0, a0, MM_WILD_OFF
    jal  ra, sp_write
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

mm_align16:
    addi a0, a0, 15
    andi a0, a0, -16
    jalr x0, ra, 0

# class idx for exact size, else -1
mm_class_for_size:
    li   t0, 32
    beq  a0, t0, mmc0
    li   t0, 64
    beq  a0, t0, mmc1
    li   t0, 128
    beq  a0, t0, mmc2
    li   t0, 256
    beq  a0, t0, mmc3
    li   t0, 512
    beq  a0, t0, mmc4
    li   t0, 1024
    beq  a0, t0, mmc5
    li   t0, 2048
    beq  a0, t0, mmc6
    li   t0, 4096
    beq  a0, t0, mmc7
    li   a0, -1
    jalr x0, ra, 0
mmc0: li a0, 0
    jalr x0, ra, 0
mmc1: li a0, 1
    jalr x0, ra, 0
mmc2: li a0, 2
    jalr x0, ra, 0
mmc3: li a0, 3
    jalr x0, ra, 0
mmc4: li a0, 4
    jalr x0, ra, 0
mmc5: li a0, 5
    jalr x0, ra, 0
mmc6: li a0, 6
    jalr x0, ra, 0
mmc7: li a0, 7
    jalr x0, ra, 0

# round req up to nearest size class (or leave as-is if >4096)
mm_round_up_class:
    li   t0, 32
    bgeu t0, a0, mmr_32
    li   t0, 64
    bgeu t0, a0, mmr_64
    li   t0, 128
    bgeu t0, a0, mmr_128
    li   t0, 256
    bgeu t0, a0, mmr_256
    li   t0, 512
    bgeu t0, a0, mmr_512
    li   t0, 1024
    bgeu t0, a0, mmr_1024
    li   t0, 2048
    bgeu t0, a0, mmr_2048
    li   t0, 4096
    bgeu t0, a0, mmr_4096
    jalr x0, ra, 0
mmr_32:
    li   a0, 32
    jalr x0, ra, 0
mmr_64:
    li   a0, 64
    jalr x0, ra, 0
mmr_128:
    li   a0, 128
    jalr x0, ra, 0
mmr_256:
    li   a0, 256
    jalr x0, ra, 0
mmr_512:
    li   a0, 512
    jalr x0, ra, 0
mmr_1024:
    li   a0, 1024
    jalr x0, ra, 0
mmr_2048:
    li   a0, 2048
    jalr x0, ra, 0
mmr_4096:
    li   a0, 4096
    jalr x0, ra, 0

mm_write_alloc_hdr:
    addi sp, sp, -4
    sw   ra, 0(sp)
    sw   a1, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    li   t0, MM_ALLOC_MAGIC
    sw   t0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    jal  ra, sp_write
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0

# pop class → a0=payload or 0
mm_pop_class:
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    slli t0, a0, 4
    li   a0, MM_BASE
    addi a0, a0, MM_HEADS_OFF
    add  s1, a0, t0
    mv   a0, s1
    jal  ra, sp_read
    lw   s0, SP_DATA0(s11)
    beq  s0, x0, mmp_empty
    mv   a0, s0
    jal  ra, sp_read
    lw   t1, SP_DATA0(s11)
    lw   t2, SP_DATA2(s11)
    sw   t1, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s1
    jal  ra, sp_write
    sw   t2, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    li   t0, MM_ALLOC_MAGIC
    sw   t0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, MM_HDR_BYTES
    j    mmp_out
mmp_empty:
    li   a0, 0
mmp_out:
    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0

# push class: a0=hdr a1=size a2=class_idx
mm_push_class:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    sw   s2, 0(sp)
    mv   s0, a0
    mv   s1, a1
    slli t0, a2, 4
    li   a0, MM_BASE
    addi a0, a0, MM_HEADS_OFF
    add  s2, a0, t0
    mv   a0, s2
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    li   t0, MM_FREE_MAGIC
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    addi a0, s0, 16
    jal  ra, sp_write
    sw   s0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s2
    jal  ra, sp_write
    lw   s2, 0(sp)
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    jalr x0, ra, 0

mm_push_gen:
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    mv   s0, a0
    mv   s1, a1
    li   a0, MM_BASE
    addi a0, a0, MM_GEN_OFF
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   s1, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    li   t0, MM_FREE_MAGIC
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    addi a0, s0, 16
    jal  ra, sp_write
    sw   s0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    li   a0, MM_BASE
    addi a0, a0, MM_GEN_OFF
    jal  ra, sp_write
    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
    jalr x0, ra, 0

# first-fit gen; a0=req → a0=payload or 0. Does not split (keeps whole block).
mm_alloc_from_gen:
    addi sp, sp, -20
    sw   ra, 16(sp)
    sw   s0, 12(sp)
    sw   s1, 8(sp)
    sw   s2, 4(sp)
    sw   s3, 0(sp)
    mv   s0, a0
    li   a0, MM_BASE
    addi a0, a0, MM_GEN_OFF
    mv   s3, a0
    jal  ra, sp_read
    lw   s1, SP_DATA0(s11)
mmag_loop:
    beq  s1, x0, mmag_fail
    mv   a0, s1
    jal  ra, sp_read
    lw   s2, SP_DATA0(s11)
    lw   t3, SP_DATA2(s11)
    bltu t3, s0, mmag_next
    sw   s2, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s3
    jal  ra, sp_write
    sw   t3, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    li   t0, MM_ALLOC_MAGIC
    sw   t0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s1
    jal  ra, sp_write
    addi a0, s1, MM_HDR_BYTES
    j    mmag_out
mmag_next:
    mv   s3, s1
    mv   s1, s2
    j    mmag_loop
mmag_fail:
    li   a0, 0
mmag_out:
    lw   s3, 0(sp)
    lw   s2, 4(sp)
    lw   s1, 8(sp)
    lw   s0, 12(sp)
    lw   ra, 16(sp)
    addi sp, sp, 20
    jalr x0, ra, 0

# ---- mm_prefill(a0=payload, a1=size, a2=hk) — for LIST/DICT/SET kinds the
# caller passes object+table in one region for NONE only; LIST/DICT/SET
# prefill expects payload to BE the object address with table following, OR
# we keep prefill minimal: only zero/write when hk!=NONE and payload is the
# object. For grow paths we use NONE. Prefill used by BUILD-style callers.
mm_prefill:
    beq  a2, x0, mmpf_ret
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    sw   s2, 0(sp)
    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    li   t0, MM_HK_LIST
    beq  s2, t0, mmpf_list
    li   t0, MM_HK_DICT
    beq  s2, t0, mmpf_dict
    li   t0, MM_HK_SET
    beq  s2, t0, mmpf_set
    j    mmpf_done
mmpf_list:
    # payload layout: [obj 32B][buf ...]; a1 was total size; capacity in
    # SCR_A0 if set — for v1 write empty list header {cap=0,len=0,ob=0}
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    jal  ra, sp_write
    j    mmpf_done
mmpf_dict:
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    jal  ra, sp_write
    j    mmpf_done
mmpf_set:
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s0
    jal  ra, sp_write
    addi a0, s0, 16
    sw   x0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    jal  ra, sp_write
mmpf_done:
    lw   s2, 0(sp)
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
mmpf_ret:
    jalr x0, ra, 0

# ---- mm_alloc -------------------------------------------------------------
mm_alloc:
    addi sp, sp, -24
    sw   ra, 20(sp)
    sw   s0, 16(sp)
    sw   s1, 12(sp)
    sw   s2, 8(sp)
    sw   s3, 4(sp)
    sw   s4, 0(sp)
    mv   s0, a0
    mv   s2, a2
    jal  ra, mm_ensure_init
    mv   a0, s0
    jal  ra, mm_align16
    mv   s0, a0
    jal  ra, mm_round_up_class
    mv   s1, a0
    mv   a0, s1
    jal  ra, mm_class_for_size
    li   t0, -1
    beq  a0, t0, mma_gen
    jal  ra, mm_pop_class
    beq  a0, x0, mma_gen
    mv   s4, a0
    j    mma_ok
mma_gen:
    mv   a0, s1
    jal  ra, mm_alloc_from_gen
    beq  a0, x0, mma_wild
    mv   s4, a0
    j    mma_ok
mma_wild:
    jal  ra, mm_wilderness_get
    mv   s3, a0
    addi t0, s1, MM_HDR_BYTES
    add  t0, s3, t0
    li   t1, HEAP_LIMIT
    bltu t1, t0, mma_oom
    mv   a0, s3
    mv   a1, s1
    jal  ra, mm_write_alloc_hdr
    addi t0, s1, MM_HDR_BYTES
    add  a0, s3, t0
    jal  ra, mm_wilderness_set
    addi s4, s3, MM_HDR_BYTES
    j    mma_ok
mma_oom:
    li   a0, 1
    li   a1, 0
    li   a2, 0
    j    mma_ret
mma_ok:
    mv   a0, s4
    mv   a1, s1
    mv   a2, s2
    jal  ra, mm_prefill
    li   a0, 0
    mv   a1, s1
    mv   a2, s4
mma_ret:
    lw   s4, 0(sp)
    lw   s3, 4(sp)
    lw   s2, 8(sp)
    lw   s1, 12(sp)
    lw   s0, 16(sp)
    lw   ra, 20(sp)
    addi sp, sp, 24
    jalr x0, ra, 0

# ---- mm_free(a0=payload) — coalesce forward with adjacent free ------------
mm_free:
    beq  a0, x0, mmf_ret
    addi sp, sp, -20
    sw   ra, 16(sp)
    sw   s0, 12(sp)
    sw   s1, 8(sp)
    sw   s2, 4(sp)
    sw   s3, 0(sp)
    addi s0, a0, -16                # hdr
    mv   a0, s0
    jal  ra, sp_read
    lw   s1, SP_DATA0(s11)          # size
    lw   t0, SP_DATA2(s11)
    li   t1, MM_ALLOC_MAGIC
    bne  t0, t1, mmf_done           # not an MM block — leave alone
    # forward coalesce: peek next hdr at s0+16+size
    addi t0, s1, MM_HDR_BYTES
    add  s2, s0, t0                 # next hdr candidate
    li   t1, HEAP_LIMIT
    bgeu s2, t1, mmf_push
    mv   a0, s2
    addi a0, a0, 16
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    li   t1, MM_FREE_MAGIC
    bne  t0, t1, mmf_push
    # next is free — unlink from its list and absorb
    mv   a0, s2
    jal  ra, sp_read
    lw   s3, SP_DATA2(s11)          # next size
    # unlink s2 from class or gen (scan class heads + gen)
    mv   a0, s2
    jal  ra, mm_unlink_free
    add  s1, s1, s3
    addi s1, s1, MM_HDR_BYTES       # absorbed hdr too
mmf_push:
    mv   a0, s1
    jal  ra, mm_class_for_size
    li   t0, -1
    beq  a0, t0, mmf_gen
    mv   a2, a0
    mv   a0, s0
    mv   a1, s1
    jal  ra, mm_push_class
    j    mmf_done
mmf_gen:
    mv   a0, s0
    mv   a1, s1
    jal  ra, mm_push_gen
mmf_done:
    lw   s3, 0(sp)
    lw   s2, 4(sp)
    lw   s1, 8(sp)
    lw   s0, 12(sp)
    lw   ra, 16(sp)
    addi sp, sp, 20
mmf_ret:
    jalr x0, ra, 0

# unlink free block a0=hdr from class heads or gen list.
# Head slots only store the pointer in word0; free-block nodes store
# {next,size} — when patching a node, preserve size (DATA2).
mm_unlink_free:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    sw   s2, 0(sp)
    mv   s0, a0
    li   s1, 0
mmul_cls:
    li   t0, 8
    beq  s1, t0, mmul_gen
    slli t0, s1, 4
    li   a0, MM_BASE
    addi a0, a0, MM_HEADS_OFF
    add  s2, a0, t0                 # head slot
    mv   a0, s2
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    beq  t0, x0, mmul_cls_next
    bne  t0, s0, mmul_walk_start
    # head == target
    mv   a0, s0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s2
    jal  ra, sp_write
    j    mmul_done
mmul_walk_start:
    # t0 = first node; walk with prev in s2 (initially head slot — flag via SCR)
    li   t1, 1
    sw   t1, SCR_A1(x0)             # 1 = prev is head slot
mmul_walk:
    beq  t0, x0, mmul_cls_next
    beq  t0, s0, mmul_found
    mv   s2, t0
    sw   x0, SCR_A1(x0)             # prev is a free node
    mv   a0, t0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    j    mmul_walk
mmul_found:
    mv   a0, s0
    jal  ra, sp_read
    lw   t1, SP_DATA0(s11)          # target.next
    lw   t2, SCR_A1(x0)
    bne  t2, x0, mmul_patch_head
    # patch free-node prev: preserve size
    mv   a0, s2
    jal  ra, sp_read
    sw   t1, SP_DATA0(s11)
    mv   a0, s2
    jal  ra, sp_write
    j    mmul_done
mmul_patch_head:
    sw   t1, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s2
    jal  ra, sp_write
    j    mmul_done
mmul_cls_next:
    addi s1, s1, 1
    j    mmul_cls
mmul_gen:
    li   a0, MM_BASE
    addi a0, a0, MM_GEN_OFF
    mv   s2, a0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    beq  t0, x0, mmul_done
    bne  t0, s0, mmul_gen_walk_start
    mv   a0, s0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    sw   t0, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s2
    jal  ra, sp_write
    j    mmul_done
mmul_gen_walk_start:
    li   t1, 1
    sw   t1, SCR_A1(x0)
mmul_gen_walk:
    beq  t0, x0, mmul_done
    beq  t0, s0, mmul_gen_found
    mv   s2, t0
    sw   x0, SCR_A1(x0)
    mv   a0, t0
    jal  ra, sp_read
    lw   t0, SP_DATA0(s11)
    j    mmul_gen_walk
mmul_gen_found:
    mv   a0, s0
    jal  ra, sp_read
    lw   t1, SP_DATA0(s11)
    lw   t2, SCR_A1(x0)
    bne  t2, x0, mmul_gen_patch_head
    mv   a0, s2
    jal  ra, sp_read
    sw   t1, SP_DATA0(s11)
    mv   a0, s2
    jal  ra, sp_write
    j    mmul_done
mmul_gen_patch_head:
    sw   t1, SP_DATA0(s11)
    sw   x0, SP_DATA1(s11)
    sw   x0, SP_DATA2(s11)
    sw   x0, SP_DATA3(s11)
    mv   a0, s2
    jal  ra, sp_write
mmul_done:
    lw   s2, 0(sp)
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    jalr x0, ra, 0

# ---- mm_store_res_heap: RES_HEAP_PTR ← wilderness (post-MM bump truth) ----
mm_store_res_heap:
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, mm_wilderness_get
    sw   a0, RES_HEAP_PTR(s11)
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, ra, 0
