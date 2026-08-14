# Builtins ROM wave 3 — next implementations

**Status:** **Done** (implementation on `builtins`)  
**Audience:** firmware builtins agent  
**Follow-on:** `planning/builtins_wave4_plan.md`

Related:

- Inventory: `pycore_firmware/builtins/builtins.md`
- Seed registry: `pycore/tools/image_from_source.py` → `ROM_FIRMWARE_BUILTINS`
- Tests: `pycore/tests/test_rom_firmware_seed.py`, `img_firmware_wave3*`,
  `img_firmware_sorted_kw`, `img_firmware_filter_pred`

---

## Completed

### 3A — ROM seed of ready pure-Python

Seeded into `ROM_FIRMWARE_BUILTINS`:

`divmod`, `pow`, `round`, `bin`, `hex`, `oct`, `tuple`, `min`, `list`,
`dict`, `reversed`, `filter`, `sorted`

(Plus prior wave 1–2 eight names → **21** ROM builtins total.)

**Attr helpers (wave 4 §2):** `hasattr` / `getattr` / `setattr` / `delattr` /
`isinstance` / `issubclass` are now ROM-seeded after `LOAD_ATTR` specials
for `__dict__` / `__class__` / `__base__` — see `planning/builtins_wave4_plan.md`.

**Empty `tuple()`:** works — CALL phase-7 ranged UNINIT clear preserves
`co_defaults` fills when `argc==0` (see `planning/call_kw_support_plan.md`).

### 3B — kwargs

- `sorted(iterable, reverse=False)` via CALL_KW
- `sum(..., start=)` exercised with keyword in `img_firmware_sorted_kw`
- `BI_MAX` left as builtins-dict entry (option B1)

### 3C — polish

- `pow` neg-mod path uses `raise`
- Stale CALL_KW / tuple docstrings refreshed
- `builtins.md` statuses updated

### Tests added

| Test | Role |
| --- | --- |
| `img_firmware_wave3a` | single-core numeric/string/tuple/min |
| `img_firmware_wave3_strings` | bin/hex/oct edges |
| `img_firmware_wave3_pow` | pow/divmod/min edges |
| `img_firmware_wave3_containers` | two-core list/sorted/reversed/tuple/dict/filter |
| `img_firmware_sorted_kw` | two-core `reverse=` + `sum(start=)` |
| `img_firmware_filter_pred` | two-core filter with predicate |
| `test_rom_firmware_seed` | registry validate, seed, host semantics, image build |

Makefile targets wired into `pycore-img-attr-all` / image-test lists.

---

## Historical goals (kept for context)

See git history of this file for the original 3A/3B checklists. Active work
continues in `planning/builtins_wave4_plan.md`.
