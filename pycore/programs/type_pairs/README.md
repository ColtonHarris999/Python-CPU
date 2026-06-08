PyCore type-pair fixtures
=========================

`add_pairs.py` and `mul_pairs.py` contain one simple Python function per
Python-representable operand tag pairing:

- `INT`
- `FLOAT`
- `BOOL`
- `OBJECT` via `None`

Each fixture has metadata describing the expected PyCore hardware result tag or
trap. `PTR` and `UNINITIALIZED` do not have direct Python literals; those tags
are covered in the RTL matrix test `pycore/tb/tb_type_pairs.sv`.
