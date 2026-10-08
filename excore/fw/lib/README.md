# Shared firmware library

Slot-port helpers live in `list_grow.s` until the C runtime (decision D2)
replaces them. The pinned toolchain is a RV32I GCC, assembly only for the
trap entry. The image documents the package; the Docker pin lands with the
first C fallback (P8).
