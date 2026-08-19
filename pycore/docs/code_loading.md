# PyCore code loading

How bytecode gets into memory and becomes executable. Companion to
`architecture.md` (memory map) and `object_model.md` (code objects).

Status: **Plan 1 P1 shipped** (the two code regions and the fetch mux). The
module image format and loader are P2 and are not implemented yet; §4 records
the intended design so the region layout is not re-litigated when it lands.

## 1. The code address space

The PC is a **slot index**, not a byte address; fetch converts it with
`pc << 3` because every code word is 8 bytes. Two banks share that space:

```text
slot 0x0000 .. 0x1FFF   CODE ROM   pycore_imem      READ_ONLY, $readmemh      64 KB /  8192 slots
slot 0x2000 .. 0xA1FF   CODE RAM   pycore_code_ram  writable                 256 KB / 32768 slots
```

`PYCORE_CODE_RAM_SLOT_BASE` (`0x2000`) is exactly the ROM's slot count
(`PYCORE_IMEM_BLOCK_COUNT * 4096 / 8`), so the regions abut and
**`entry_slot` semantics do not change**: code in RAM is simply code with a
large entry slot. `pycore/tests/test_code_ram.py` pins that relationship, along
with the tooling mirrors in `encoding.py`, so the two copies of the geometry
cannot drift.

`pycore_code_mem.sv` is the region mux and is a drop-in replacement for
`pycore_imem`, so both tops (`pycore_system.sv`, `pycore_excore_system.sv`)
changed only the module name plus a `CODE_RAM_HEX` parameter. Both banks are the
same `pycore_mem_bank`, so read latency and the ack handshake are identical
whichever region is selected and fetch needed no new stall state.

A request at or beyond `PYCORE_CODE_RAM_SLOT_LIMIT` has no bank to answer it, so
the mux synthesises `fault_o` **and still acks** — a silent wrap or a hang would
both be worse than a fault.

### 1.1 Why two regions instead of one big writable imem

Making imem larger and writable would work in simulation and is a smaller diff,
but it gives up two things:

- **The ROM guarantee.** A buggy loader or a runaway code generator cannot
  corrupt the boot image, for the same reason real machines boot from mask ROM.
- **A relocation story.** Keeping a fixed ROM and a separately-addressed RAM is
  what makes "load this module somewhere" a meaningful operation (§4).

The cost is one address compare and a 2:1 mux.

### 1.2 Sizing rationale

PyPy's compiler — the closest existing reference for the self-hosted compiler in
Plan 2 — is about 315 KB of Python across six modules. At roughly 5–10 bytecode
units per source line, even a heavily reduced PyCore-subset compiler wants
10 000–30 000 code slots. Today's entire ROM is 8192 slots and already holds the
boot image and ROM firmware, so code RAM is sized at 32 768 slots (256 KB).

`PYCORE_CODE_RAM_BLOCK_COUNT` is a parameter. If that is too much area for a
real target, the answer is not a smaller compiler but **overlays**: the loader
in §4 exists so a module can be loaded, replaced, or paged rather than all
resident at once.

## 2. What can write code RAM

Nothing yet, at runtime. P1 delivers the region and the fetch path; the writers
arrive later:

| Writer | Phase | Mechanism |
| --- | --- | --- |
| Image preload (`CODE_RAM_HEX`) | **P1, shipped** | `$readmemh` at elaboration; test-only |
| `_bi_load_module` | P2 | Copies a module image's text section into RAM |
| `_bi_code_emit` | Plan 2 C6 | Writes one code word, for a code generator |

**Excore cannot write code memory at all.** The two cores share dmem but keep
private instruction memories, so every code-memory writer must run on-core.

**Self-modification is not supported.** Writing a slot that is currently
executing is undefined; code must be fully emitted before it is called.

## 3. Testing the region mux

Because the mux must be *transparent*, the test is a differential against
itself: `img_code_ram_call.py` is built and run twice —

- `pycore-img-code-ram-call-rom` — an ordinary ROM image.
- `pycore-img-code-ram-call` — built with `--code-ram`, which offsets every
  entry slot by `CODE_RAM_SLOT_BASE`, writes the slots to `code_ram.hex`, and
  runs with an **empty ROM** so a fetch that did not reach RAM could not work.

Both must return the same value. The program deliberately includes nested calls,
a backward branch, and builtin calls so the check covers redirects rather than
straight-line fetch only.

`--code-ram` threads a `slot_base` through the serializer
(`_ImageSerializer.slot_base`); `test_code_ram.py` asserts that relocating an
image shifts every entry slot by exactly the base and changes nothing else
about the emitted slots.

## 4. Planned: module images and relocation (P2)

Not implemented. Recorded here because §1's layout was chosen for it.

A module is **not** just code: it is code slots plus a dmem object graph
(`co_consts`, `co_names`, nested code objects, strings). Loading one means
placing both and fixing up the cross-references — the ELF-like step.

```text
PyCore module image (16-byte aligned blob in dmem)
  +0x00  magic 'PYCM' + version
  +0x08  text_slots
  +0x0C  data_bytes
  +0x10  entry_offset      offset of the entry CODE_OBJECT within the data section
  +0x14  reloc_count
  +0x18  flags
  text section              text_slots x 8 bytes; entry_slot fields MODULE-RELATIVE
  data section              data_bytes; handles DATA-SECTION-RELATIVE
  reloc table               { kind[7:0], offset[31:0] }
                            kind 0 = TEXT_SLOT_IN_DATA (add text_base)
                            kind 1 = DATA_ADDR_IN_DATA (add data_base)
```

Two relocation kinds suffice because those are the only two absolute address
spaces a module references; the kind byte leaves room for a third without a
format version bump.

`_bi_load_module(image_addr) -> CODE_OBJECT` validates the header, reserves
`text_slots` from `code_ram_ptr_r`, copies the text, bump-allocates
`data_bytes` on the heap, copies the data, applies relocations, and returns the
entry handle. Overflow of either region, or a relocation offset outside its
section, must fault rather than corrupt.

Intended phasing: fixed-base copy first, then text relocation, then data
relocation, then two modules where the second base depends on the first.
