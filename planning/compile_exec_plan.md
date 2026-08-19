# `compile()` / `exec()` — index (split into two plans)

**Status:** superseded. Phase 0 shipped; the rest was split in two.

This document was the original single plan for runtime `compile()` / `exec()` /
`eval()`. It has been replaced by two sequential plans, because the work divides
cleanly at the tokenizer and because the second half needs a code-loading
architecture the first half has to build:

| Plan | Scope |
| --- | --- |
| **[Plan 1 — code loading, BIOS, tokenizer](code_loading_bios_tokenizer_plan.md)** | Writable/relocatable code memory, a module format and loader, a Python **BIOS** that boots first and `exec()`s a payload, `exec` / `eval` on precompiled code objects, per-frame globals, slicing and string/sequence methods, string interning, exceptions with messages, heap/code marks, and an on-device **tokenizer** |
| **[Plan 2 — native compiler](native_compiler_plan.md)** | Parser, AST, symbol table, code generator, assembler, code-object fabrication, `compile()` and string `exec` / `eval`, an on-device source store, and a **self-hosting bootstrap** with no host in the loop |

Plan 1 §14 is the explicit dependency contract between them. Plan 2 §11 tracks
what remains between "no host needed" and "all of Python runs".

---

## What already shipped (phase 0)

Both items are on `main`; the analysis that motivated them is preserved in Plan 1.

| Item | Implementation |
| --- | --- |
| **`s[i]`** — character-indexed string subscript | `CONT_SUBSCR_STR` (6'd44). Walks one UTF-8 character per cycle so `s[i]` agrees with `for c in s`; returns a one-character `SHORT_STR`. Index past the end → `PY_TRAP_MEM_FAULT`; malformed UTF-8 → `PY_TRAP_TYPE` |
| **`ord` / `chr`** | Native `BI_ORD` (10) / `BI_CHR` (11). Single-cycle with no dmem or `string_mem` access, because a one-character string is always a `SHORT_STR` and its bytes are inline in the handle. `chr` rejects > U+10FFFF, negatives, and lone surrogates |

New `bytecode_support.md` deviation 14 records that `len(s)` is a **byte** count
while `s[i]` and `for c in s` are **character**-stepped.

These two turned out to be the right first primitives for a reason that shaped
both successor plans: the tokenizer's and parser's DFA tables have to be stored
as **strings read with `ord(s[i])`**, because a `TUPLE` of `INT` costs 32 bytes
per entry against a 109 KB heap while a string costs one byte per entry.

---

## Findings that carried forward

Recorded here because they are the reason the plans look the way they do; each is
expanded where it is used.

| Finding | Consequence |
| --- | --- |
| **imem is `READ_ONLY` and bytecode lives only in imem.** Code objects hold an `entry_slot`, not `co_code`; fetch hardwires `imem_we_o = 1'b0`; excore shares dmem but not imem. | Plan 1 P1/P2: a ROM region plus writable, **relocatable** code RAM with a module format and loader — not just a bump arena |
| **`exec(code_object)` needs no hardware change.** `CALL` on a `CODE_OBJECT` in a variable already works (`img_firmware_filter_pred`), and `STORE_NAME` / `LOAD_NAME` already target the module globals dict, which *is* module-scope `exec` semantics. | Plan 1 P3 ships first, with zero RTL |
| **A self-hosted ROM Python compiler is the only viable host** — excore is 16 KB of hand-written RV32I with no MUL/DIV, and a host escape would be simulation-only. | Plan 2's whole structure |
| **PyPy's tokenizer is pure Python, regex-free and generator-free**, and its DFA table construction is already a build-time step. | Plan 1 §2, §10 |
| **PyPy's compiler is ~315 KB of Python** — far past today's 64 KB imem. | Plan 1 §6.0 sizing; Plan 2 §2.3, §9.4 size budgeting |
| **Long runtime strings are not interned** (`LONG_STR` dict keys compare by descriptor), so identifiers > 15 bytes cannot be dict keys. | Promoted from a "later" item to a **hard requirement** in Plan 1 §6.4 — a compiler cannot live with it |
| **Slicing is deferred**, yet the tokenizer uses it at 14 sites. | Plan 1 §6.3.1 |
| **No GC**, and both heap and code RAM are bump allocators. | Plan 1 §9.2 mark/release; Plan 2 R1 |
