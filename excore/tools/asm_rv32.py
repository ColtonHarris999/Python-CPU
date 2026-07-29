#!/usr/bin/env python3
"""Two-pass RV32I assembler for excore firmware.

Self-contained (stdlib only; not CPython-3.14-coupled — this is not part of
the empirical-verification house rule, since RV32I encodings come from the
RISC-V ISA spec, not from probing a running interpreter).

Supported instruction subset (must match excore_cpu.sv exactly):
  LUI, AUIPC, JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU, LW, SW,
  ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI,
  ADD, SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA.

Pseudo-ops: li (LUI+ADDI, or plain ADDI when it fits in 12 bits), j (JAL x0),
mv (ADDI rd,rs,0), nop (ADDI x0,x0,0).

Directives: labels (`label:`), `.word <expr>`, `.equ NAME, VALUE`.
Operand syntax: `%hi(expr)` / `%lo(expr)` for absolute-address loads
(`lui rd, %hi(label)` / `addi rd, rd, %lo(label)`).

Two passes:
  Pass 1: walk the source, assigning a word address (multiple of 4) to every
          real instruction / `.word`, and recording label -> address.
  Pass 2: re-walk, resolving every label/`.equ` reference and encoding each
          instruction to a 32-bit word. Branch/jump immediates are range-
          checked here (AsmError on overflow).

Output: a `$readmemh`-style hex file, one 32-bit word per line (8 hex
digits), suitable for `excore_cpu`'s `FW_HEX` parameter.
"""

from __future__ import annotations

import argparse
import pathlib
import re
from dataclasses import dataclass, field

WORD_BYTES = 4


class AsmError(Exception):
    pass


# ---------------------------------------------------------------------------
# Registers
# ---------------------------------------------------------------------------

_ABI_ALIASES = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25,
    "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}


def parse_reg(tok: str) -> int:
    tok = tok.strip().lower()
    if tok in _ABI_ALIASES:
        return _ABI_ALIASES[tok]
    m = re.fullmatch(r"x(\d{1,2})", tok)
    if m:
        n = int(m.group(1))
        if 0 <= n <= 31:
            return n
    raise AsmError(f"invalid register {tok!r}")


# ---------------------------------------------------------------------------
# Instruction format encoders (pure functions of already-resolved fields)
# ---------------------------------------------------------------------------

def enc_r(opcode: int, rd: int, funct3: int, rs1: int, rs2: int, funct7: int) -> int:
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
        | ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_i(opcode: int, rd: int, funct3: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) \
        | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_s(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    imm12 = imm & 0xFFF
    imm_hi = (imm12 >> 5) & 0x7F
    imm_lo = imm12 & 0x1F
    return (imm_hi << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
        | ((funct3 & 0x7) << 12) | (imm_lo << 7) | (opcode & 0x7F)


def enc_b(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    if imm % 2 != 0:
        raise AsmError(f"branch offset {imm} is not 2-byte aligned")
    if not (-4096 <= imm <= 4094):
        raise AsmError(f"branch offset {imm} out of range for B-type (+/-4KiB)")
    imm13 = imm & 0x1FFF
    bit12 = (imm13 >> 12) & 1
    bit11 = (imm13 >> 11) & 1
    bits10_5 = (imm13 >> 5) & 0x3F
    bits4_1 = (imm13 >> 1) & 0xF
    return (bit12 << 31) | (bits10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
        | ((funct3 & 0x7) << 12) | (bits4_1 << 8) | (bit11 << 7) | (opcode & 0x7F)


def enc_u(opcode: int, rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_j(opcode: int, rd: int, imm: int) -> int:
    if imm % 2 != 0:
        raise AsmError(f"jump offset {imm} is not 2-byte aligned")
    if not (-1048576 <= imm <= 1048574):
        raise AsmError(f"jump offset {imm} out of range for J-type (+/-1MiB)")
    imm21 = imm & 0x1FFFFF
    bit20 = (imm21 >> 20) & 1
    bits19_12 = (imm21 >> 12) & 0xFF
    bit11 = (imm21 >> 11) & 1
    bits10_1 = (imm21 >> 1) & 0x3FF
    return (bit20 << 31) | (bits10_1 << 21) | (bit11 << 20) | (bits19_12 << 12) \
        | ((rd & 0x1F) << 7) | (opcode & 0x7F)


# ---------------------------------------------------------------------------
# Opcode / funct3 / funct7 table (RV32I subset supported by excore_cpu.sv)
# ---------------------------------------------------------------------------

OPC_OP_IMM = 0b0010011
OPC_OP = 0b0110011
OPC_LOAD = 0b0000011
OPC_STORE = 0b0100011
OPC_BRANCH = 0b1100011
OPC_JALR = 0b1100111
OPC_JAL = 0b1101111
OPC_LUI = 0b0110111
OPC_AUIPC = 0b0010111

# name -> (opcode, funct3, funct7)
R_TYPE = {
    "add": (OPC_OP, 0b000, 0b0000000),
    "sub": (OPC_OP, 0b000, 0b0100000),
    "sll": (OPC_OP, 0b001, 0b0000000),
    "slt": (OPC_OP, 0b010, 0b0000000),
    "sltu": (OPC_OP, 0b011, 0b0000000),
    "xor": (OPC_OP, 0b100, 0b0000000),
    "srl": (OPC_OP, 0b101, 0b0000000),
    "sra": (OPC_OP, 0b101, 0b0100000),
    "or": (OPC_OP, 0b110, 0b0000000),
    "and": (OPC_OP, 0b111, 0b0000000),
}

# name -> (opcode, funct3)
I_ARITH = {
    "addi": (OPC_OP_IMM, 0b000),
    "slti": (OPC_OP_IMM, 0b010),
    "sltiu": (OPC_OP_IMM, 0b011),
    "xori": (OPC_OP_IMM, 0b100),
    "ori": (OPC_OP_IMM, 0b110),
    "andi": (OPC_OP_IMM, 0b111),
}

# name -> (opcode, funct3, funct7) — shift amount goes in imm[4:0]
I_SHIFT = {
    "slli": (OPC_OP_IMM, 0b001, 0b0000000),
    "srli": (OPC_OP_IMM, 0b101, 0b0000000),
    "srai": (OPC_OP_IMM, 0b101, 0b0100000),
}

B_TYPE = {
    "beq": 0b000,
    "bne": 0b001,
    "blt": 0b100,
    "bge": 0b101,
    "bltu": 0b110,
    "bgeu": 0b111,
}

PSEUDO_OPS = {"li", "j", "mv", "nop"}
ALL_MNEMONICS = (
    set(R_TYPE) | set(I_ARITH) | set(I_SHIFT) | set(B_TYPE) | PSEUDO_OPS
    | {"lw", "sw", "jal", "jalr", "lui", "auipc"}
)


# ---------------------------------------------------------------------------
# Source line model
# ---------------------------------------------------------------------------

@dataclass
class SourceLine:
    lineno: int
    label: str | None
    mnemonic: str | None
    operands: list[str]
    directive: str | None = None
    directive_args: list[str] = field(default_factory=list)


def strip_comment(text: str) -> str:
    for marker in ("#", ";", "//"):
        idx = text.find(marker)
        if idx != -1:
            text = text[:idx]
    return text


def split_operands(rest: str) -> list[str]:
    rest = rest.strip()
    if not rest:
        return []
    return [op.strip() for op in rest.split(",")]


def parse_lines(text: str) -> list[SourceLine]:
    lines: list[SourceLine] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        code = strip_comment(raw).strip()
        if not code:
            continue

        label = None
        m = re.match(r"^([A-Za-z_.$][A-Za-z0-9_.$]*)\s*:\s*(.*)$", code)
        if m:
            label = m.group(1)
            code = m.group(2).strip()
            if not code:
                lines.append(SourceLine(lineno, label, None, []))
                continue

        if code.startswith("."):
            parts = code.split(None, 1)
            directive = parts[0][1:]
            args = split_operands(parts[1]) if len(parts) > 1 else []
            lines.append(SourceLine(lineno, label, None, [], directive, args))
            continue

        parts = code.split(None, 1)
        mnemonic = parts[0].lower()
        operands = split_operands(parts[1]) if len(parts) > 1 else []
        lines.append(SourceLine(lineno, label, mnemonic, operands))
    return lines


# ---------------------------------------------------------------------------
# Expression / immediate parsing (labels, %hi/%lo, .equ constants, literals)
# ---------------------------------------------------------------------------

_HI_RE = re.compile(r"^%hi\((.+)\)$")
_LO_RE = re.compile(r"^%lo\((.+)\)$")


def parse_int_literal(tok: str) -> int | None:
    tok = tok.strip()
    try:
        return int(tok, 0)
    except ValueError:
        return None


class Assembler:
    def __init__(self) -> None:
        self.equs: dict[str, int] = {}
        self.labels: dict[str, int] = {}

    def resolve_symbol(self, name: str) -> int:
        if name in self.labels:
            return self.labels[name]
        if name in self.equs:
            return self.equs[name]
        lit = parse_int_literal(name)
        if lit is not None:
            return lit
        raise AsmError(f"undefined symbol {name!r}")

    def resolve_imm(self, tok: str) -> int:
        """Resolve a bare immediate/label/.equ token to an absolute value."""
        tok = tok.strip()
        m = _HI_RE.match(tok)
        if m:
            val = self.resolve_symbol(m.group(1).strip())
            return (val >> 12) & 0xFFFFF if val >= 0 else ((val >> 12) & 0xFFFFF)
        m = _LO_RE.match(tok)
        if m:
            val = self.resolve_symbol(m.group(1).strip())
            lo = val & 0xFFF
            # Sign-extend so a matching ADDI %lo() reproduces the low 12 bits
            # exactly even when bit 11 is set (standard RV32 hi/lo split).
            return lo - 0x1000 if lo & 0x800 else lo
        return self.resolve_symbol(tok)

    def hi20(self, val: int) -> int:
        """%hi() companion for `li`/absolute addressing: round-trip-correct
        high 20 bits, compensating for %lo()'s sign extension."""
        lo = val & 0xFFF
        lo_signed = lo - 0x1000 if lo & 0x800 else lo
        return ((val - lo_signed) >> 12) & 0xFFFFF


# ---------------------------------------------------------------------------
# Pass 1: address assignment
# ---------------------------------------------------------------------------

@dataclass
class PendingWord:
    addr: int
    line: SourceLine


def expand_pseudo_count(line: SourceLine, asm: Assembler) -> int:
    """Number of 4-byte words a pseudo-op or real instruction occupies.

    `li` needs to know at pass-1 time whether the immediate fits in 12 bits
    (1 word) or needs LUI+ADDI (2 words). Labels/.equs used inside `li`'s
    immediate are resolved best-effort here; forward references to labels
    fall back to the conservative 2-word form.
    """
    if line.mnemonic != "li":
        return 1
    if len(line.operands) != 2:
        raise AsmError(f"line {line.lineno}: li takes 2 operands")
    imm_tok = line.operands[1]
    lit = parse_int_literal(imm_tok)
    if lit is None:
        lit = asm.equs.get(imm_tok, asm.labels.get(imm_tok))
    if lit is not None and -2048 <= lit <= 2047:
        return 1
    return 2


def assemble_pass1(lines: list[SourceLine]) -> Assembler:
    asm = Assembler()
    addr = 0
    for line in lines:
        if line.label is not None:
            if line.label in asm.labels:
                raise AsmError(f"line {line.lineno}: duplicate label {line.label!r}")
            asm.labels[line.label] = addr

        if line.directive == "equ":
            if len(line.directive_args) != 2:
                raise AsmError(f"line {line.lineno}: .equ takes NAME, VALUE")
            name, val_tok = line.directive_args
            asm.equs[name.strip()] = asm.resolve_imm(val_tok)
            continue

        if line.directive == "word":
            addr += WORD_BYTES * max(1, len(line.directive_args))
            continue

        if line.directive is not None:
            raise AsmError(f"line {line.lineno}: unknown directive .{line.directive}")

        if line.mnemonic is None:
            continue

        if line.mnemonic not in ALL_MNEMONICS:
            raise AsmError(f"line {line.lineno}: unknown mnemonic {line.mnemonic!r}")

        addr += WORD_BYTES * expand_pseudo_count(line, asm)

    return asm


# ---------------------------------------------------------------------------
# Pass 2: encode
# ---------------------------------------------------------------------------

def assemble_pass2(lines: list[SourceLine], asm: Assembler) -> list[int]:
    words: list[int] = []
    addr = 0

    def emit(word: int) -> None:
        nonlocal addr
        words.append(word & 0xFFFFFFFF)
        addr += WORD_BYTES

    for line in lines:
        if line.directive == "equ":
            continue
        if line.directive == "word":
            for a in line.directive_args:
                emit(asm.resolve_imm(a))
            continue
        if line.directive is not None:
            continue
        if line.mnemonic is None:
            continue

        m = line.mnemonic
        ops = line.operands

        if m == "nop":
            emit(enc_i(OPC_OP_IMM, 0, 0b000, 0, 0))
            continue

        if m == "mv":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: mv rd, rs")
            rd, rs = parse_reg(ops[0]), parse_reg(ops[1])
            emit(enc_i(OPC_OP_IMM, rd, 0b000, rs, 0))
            continue

        if m == "j":
            if len(ops) != 1:
                raise AsmError(f"line {line.lineno}: j label")
            target = asm.resolve_symbol(ops[0])
            emit(enc_j(OPC_JAL, 0, target - addr))
            continue

        if m == "li":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: li rd, imm")
            rd = parse_reg(ops[0])
            lit = parse_int_literal(ops[1])
            if lit is None:
                lit = asm.resolve_symbol(ops[1])
            if -2048 <= lit <= 2047:
                emit(enc_i(OPC_OP_IMM, rd, 0b000, 0, lit))
            else:
                emit(enc_u(OPC_LUI, rd, asm.hi20(lit)))
                lo = lit & 0xFFF
                lo_signed = lo - 0x1000 if lo & 0x800 else lo
                emit(enc_i(OPC_OP_IMM, rd, 0b000, rd, lo_signed))
            continue

        if m in R_TYPE:
            if len(ops) != 3:
                raise AsmError(f"line {line.lineno}: {m} rd, rs1, rs2")
            opcode, f3, f7 = R_TYPE[m]
            rd, rs1, rs2 = (parse_reg(o) for o in ops)
            emit(enc_r(opcode, rd, f3, rs1, rs2, f7))
            continue

        if m in I_ARITH:
            if len(ops) != 3:
                raise AsmError(f"line {line.lineno}: {m} rd, rs1, imm")
            opcode, f3 = I_ARITH[m]
            rd, rs1 = parse_reg(ops[0]), parse_reg(ops[1])
            imm = asm.resolve_imm(ops[2])
            if not (-2048 <= imm <= 4095):
                raise AsmError(f"line {line.lineno}: immediate {imm} out of I-type range")
            emit(enc_i(opcode, rd, f3, rs1, imm))
            continue

        if m in I_SHIFT:
            if len(ops) != 3:
                raise AsmError(f"line {line.lineno}: {m} rd, rs1, shamt")
            opcode, f3, f7 = I_SHIFT[m]
            rd, rs1 = parse_reg(ops[0]), parse_reg(ops[1])
            shamt = asm.resolve_imm(ops[2])
            if not (0 <= shamt <= 31):
                raise AsmError(f"line {line.lineno}: shift amount {shamt} out of range")
            emit(enc_i(opcode, rd, f3, rs1, (f7 << 5) | shamt))
            continue

        if m == "lw":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: lw rd, imm(rs1)")
            rd = parse_reg(ops[0])
            imm, rs1 = parse_mem_operand(ops[1], asm)
            emit(enc_i(OPC_LOAD, rd, 0b010, rs1, imm))
            continue

        if m == "sw":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: sw rs2, imm(rs1)")
            rs2 = parse_reg(ops[0])
            imm, rs1 = parse_mem_operand(ops[1], asm)
            emit(enc_s(OPC_STORE, 0b010, rs1, rs2, imm))
            continue

        if m in B_TYPE:
            if len(ops) != 3:
                raise AsmError(f"line {line.lineno}: {m} rs1, rs2, label")
            f3 = B_TYPE[m]
            rs1, rs2 = parse_reg(ops[0]), parse_reg(ops[1])
            target = asm.resolve_symbol(ops[2])
            emit(enc_b(OPC_BRANCH, f3, rs1, rs2, target - addr))
            continue

        if m == "jal":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: jal rd, label")
            rd = parse_reg(ops[0])
            target = asm.resolve_symbol(ops[1])
            emit(enc_j(OPC_JAL, rd, target - addr))
            continue

        if m == "jalr":
            if len(ops) != 3:
                raise AsmError(f"line {line.lineno}: jalr rd, rs1, imm")
            rd, rs1 = parse_reg(ops[0]), parse_reg(ops[1])
            imm = asm.resolve_imm(ops[2])
            emit(enc_i(OPC_JALR, rd, 0b000, rs1, imm))
            continue

        if m == "lui":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: lui rd, imm")
            rd = parse_reg(ops[0])
            emit(enc_u(OPC_LUI, rd, asm.resolve_imm(ops[1])))
            continue

        if m == "auipc":
            if len(ops) != 2:
                raise AsmError(f"line {line.lineno}: auipc rd, imm")
            rd = parse_reg(ops[0])
            emit(enc_u(OPC_AUIPC, rd, asm.resolve_imm(ops[1])))
            continue

        raise AsmError(f"line {line.lineno}: unhandled mnemonic {m!r}")

    return words


def parse_mem_operand(tok: str, asm: Assembler) -> tuple[int, int]:
    """Parse `imm(rs1)` into (imm, rs1_index)."""
    m = re.fullmatch(r"\s*(.*?)\s*\(\s*(\w+)\s*\)\s*", tok)
    if not m:
        raise AsmError(f"invalid memory operand {tok!r} (expected imm(rs1))")
    imm_tok, reg_tok = m.group(1), m.group(2)
    imm = asm.resolve_imm(imm_tok) if imm_tok else 0
    return imm, parse_reg(reg_tok)


# ---------------------------------------------------------------------------
# Top-level API
# ---------------------------------------------------------------------------

def assemble(text: str) -> list[int]:
    lines = parse_lines(text)
    asm = assemble_pass1(lines)
    return assemble_pass2(lines, asm)


def words_to_hex(words: list[int]) -> str:
    return "\n".join(f"{w:08x}" for w in words) + ("\n" if words else "")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="RV32I assembly source file")
    parser.add_argument("-o", "--output", required=True, help="output $readmemh hex file")
    args = parser.parse_args()

    src_path = pathlib.Path(args.source)
    words = assemble(src_path.read_text(encoding="utf-8"))
    out_path = pathlib.Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(words_to_hex(words), encoding="ascii")
    print(f"Assembled {len(words)} words -> {out_path}")


if __name__ == "__main__":
    main()
