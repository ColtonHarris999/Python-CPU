"""Golden-encoding unit tests for excore/tools/asm_rv32.py.

Expected words are hand-computed against the RV32I bit layouts (not derived
from the assembler itself), one per instruction format (R/I/S/B/U/J), plus a
branch-range error case and a small end-to-end program exercising labels and
pseudo-ops.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))

import asm_rv32 as asm  # noqa: E402


class TestGoldenEncodings(unittest.TestCase):
    def test_r_type_add(self) -> None:
        # add x1, x2, x3 -> funct7=0 rs2=3 rs1=2 funct3=0 rd=1 opcode=0110011
        got = asm.assemble("add x1, x2, x3\n")
        self.assertEqual(got, [0x003100B3])

    def test_i_type_addi(self) -> None:
        # addi x1, x0, 5 -> imm=5 rs1=0 funct3=0 rd=1 opcode=0010011
        got = asm.assemble("addi x1, x0, 5\n")
        self.assertEqual(got, [0x00500093])

    def test_s_type_sw(self) -> None:
        # sw x2, 4(x1) -> imm=4 rs2=2 rs1=1 funct3=010 opcode=0100011
        got = asm.assemble("sw x2, 4(x1)\n")
        self.assertEqual(got, [0x0020A223])

    def test_b_type_beq(self) -> None:
        # beq x1, x2, target  where target is 8 bytes after beq itself
        src = "beq x1, x2, target\nnop\ntarget:\nnop\n"
        got = asm.assemble(src)
        self.assertEqual(got[0], 0x00208463)

    def test_u_type_lui(self) -> None:
        # lui x5, 0x12345
        got = asm.assemble("lui x5, 0x12345\n")
        self.assertEqual(got, [0x123452B7])

    def test_j_type_jal(self) -> None:
        # jal x1, target where target is 16 bytes after jal itself
        src = "jal x1, target\nnop\nnop\nnop\ntarget:\nnop\n"
        got = asm.assemble(src)
        self.assertEqual(got[0], 0x010000EF)

    def test_i_type_load(self) -> None:
        # lw x3, 0(x2) -> imm=0 rs1=2 funct3=010 rd=3 opcode=0000011
        got = asm.assemble("lw x3, 0(x2)\n")
        expected = asm.enc_i(asm.OPC_LOAD, 3, 0b010, 2, 0)
        self.assertEqual(got, [expected])

    def test_i_type_shift(self) -> None:
        # slli x4, x4, 3
        got = asm.assemble("slli x4, x4, 3\n")
        expected = asm.enc_i(asm.OPC_OP_IMM, 4, 0b001, 4, 3)
        self.assertEqual(got, [expected])
        # srai has funct7 bit set in imm[11:5]
        got_srai = asm.assemble("srai x4, x4, 3\n")
        expected_srai = asm.enc_i(asm.OPC_OP_IMM, 4, 0b101, 4, (0b0100000 << 5) | 3)
        self.assertEqual(got_srai, [expected_srai])

    def test_jalr(self) -> None:
        got = asm.assemble("jalr x1, x2, 4\n")
        expected = asm.enc_i(asm.OPC_JALR, 1, 0b000, 2, 4)
        self.assertEqual(got, [expected])


class TestBranchRangeError(unittest.TestCase):
    def test_branch_too_far_forward_raises(self) -> None:
        # +4096 is one past the max encodable B-type offset (+4094, even-only).
        with self.assertRaises(asm.AsmError):
            asm.enc_b(asm.OPC_BRANCH, 0b000, 1, 2, 4096)

    def test_branch_too_far_backward_raises(self) -> None:
        with self.assertRaises(asm.AsmError):
            asm.enc_b(asm.OPC_BRANCH, 0b000, 1, 2, -4098)

    def test_branch_odd_offset_raises(self) -> None:
        with self.assertRaises(asm.AsmError):
            asm.enc_b(asm.OPC_BRANCH, 0b000, 1, 2, 5)

    def test_branch_at_max_range_ok(self) -> None:
        # +4094 and -4096 are the exact boundary values and must succeed.
        asm.enc_b(asm.OPC_BRANCH, 0b000, 1, 2, 4094)
        asm.enc_b(asm.OPC_BRANCH, 0b000, 1, 2, -4096)

    def test_jump_too_far_raises(self) -> None:
        with self.assertRaises(asm.AsmError):
            asm.enc_j(asm.OPC_JAL, 0, 1048576)


class TestPseudoOps(unittest.TestCase):
    def test_nop_is_addi_x0_x0_0(self) -> None:
        got = asm.assemble("nop\n")
        self.assertEqual(got, [asm.enc_i(asm.OPC_OP_IMM, 0, 0, 0, 0)])

    def test_mv_is_addi_zero_shift(self) -> None:
        got = asm.assemble("mv x5, x6\n")
        self.assertEqual(got, [asm.enc_i(asm.OPC_OP_IMM, 5, 0, 6, 0)])

    def test_j_is_jal_x0(self) -> None:
        src = "j target\nnop\ntarget:\nnop\n"
        got = asm.assemble(src)
        self.assertEqual(got[0], asm.enc_j(asm.OPC_JAL, 0, 8))

    def test_li_small_immediate_is_one_word(self) -> None:
        got = asm.assemble("li x1, 42\n")
        self.assertEqual(got, [asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 42)])

    def test_li_negative_small_immediate(self) -> None:
        got = asm.assemble("li x1, -1\n")
        self.assertEqual(got, [asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, -1)])

    def test_li_large_immediate_expands_to_lui_addi(self) -> None:
        got = asm.assemble("li x1, 0x12345678\n")
        self.assertEqual(len(got), 2)
        # Reassemble via LUI (upper 20) + ADDI (sign-extended lower 12) and
        # confirm it reproduces the original 32-bit value bit-for-bit.
        lui_word, addi_word = got
        hi20 = (lui_word >> 12) & 0xFFFFF
        lo12 = (addi_word >> 20) & 0xFFF
        lo_signed = lo12 - 0x1000 if lo12 & 0x800 else lo12
        reconstructed = ((hi20 << 12) + lo_signed) & 0xFFFFFFFF
        self.assertEqual(reconstructed, 0x12345678)


class TestDirectivesAndSymbols(unittest.TestCase):
    def test_word_directive_literal(self) -> None:
        got = asm.assemble(".word 0xdeadbeef\n")
        self.assertEqual(got, [0xDEADBEEF])

    def test_equ_constant_used_in_addi(self) -> None:
        got = asm.assemble(".equ FOO, 7\naddi x1, x0, FOO\n")
        self.assertEqual(got, [asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 7)])

    def test_hi_lo_roundtrip_for_label_address(self) -> None:
        src = (
            ".word 0\n"      # addr 0 filler so the label isn't at 0
            "target:\n"
            ".word 0\n"
            "lui x1, %hi(target)\n"
            "addi x1, x1, %lo(target)\n"
        )
        words = asm.assemble(src)
        lui_word, addi_word = words[2], words[3]
        hi20 = (lui_word >> 12) & 0xFFFFF
        lo12 = (addi_word >> 20) & 0xFFF
        lo_signed = lo12 - 0x1000 if lo12 & 0x800 else lo12
        reconstructed = ((hi20 << 12) + lo_signed) & 0xFFFFFFFF
        self.assertEqual(reconstructed, 4)  # target's address

    def test_duplicate_label_raises(self) -> None:
        with self.assertRaises(asm.AsmError):
            asm.assemble("foo:\nnop\nfoo:\nnop\n")

    def test_unknown_mnemonic_raises(self) -> None:
        with self.assertRaises(asm.AsmError):
            asm.assemble("frobnicate x1, x2, x3\n")


class TestEndToEndProgram(unittest.TestCase):
    def test_loop_program_assembles_and_encodes_expected_word_count(self) -> None:
        src = """
            # sum 0..4 into x1
            li x1, 0
            li x2, 0
        loop:
            addi x1, x1, 1
            addi x2, x2, 1
            blt x2, x5, loop
            j done
        done:
            nop
        """
        words = asm.assemble(src)
        # 2 li (1 word each) + addi + addi + blt + j + nop = 7 words.
        self.assertEqual(len(words), 7)


class TestSemicolonSeparator(unittest.TestCase):
    """`;` is a statement separator (not a comment). `#` / `//` remain comments."""

    def test_three_instructions_on_one_line(self) -> None:
        got = asm.assemble("addi x1, x0, 1; addi x2, x0, 2; addi x3, x0, 3\n")
        self.assertEqual(
            got,
            [
                asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 1),
                asm.enc_i(asm.OPC_OP_IMM, 2, 0, 0, 2),
                asm.enc_i(asm.OPC_OP_IMM, 3, 0, 0, 3),
            ],
        )

    def test_label_binds_to_first_of_semicolon_group(self) -> None:
        src = "label: addi x1, x0, 1; addi x2, x0, 2\nnop\n"
        words = asm.assemble(src)
        self.assertEqual(len(words), 3)
        self.assertEqual(words[0], asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 1))
        self.assertEqual(words[1], asm.enc_i(asm.OPC_OP_IMM, 2, 0, 0, 2))
        # `%hi/%lo(label)` must resolve to address of the first insn (0).
        src2 = (
            "label: addi x1, x0, 1; addi x2, x0, 2\n"
            "lui x3, %hi(label)\n"
            "addi x3, x3, %lo(label)\n"
        )
        words2 = asm.assemble(src2)
        lui_word, addi_word = words2[2], words2[3]
        hi20 = (lui_word >> 12) & 0xFFFFF
        lo12 = (addi_word >> 20) & 0xFFF
        lo_signed = lo12 - 0x1000 if lo12 & 0x800 else lo12
        self.assertEqual(((hi20 << 12) + lo_signed) & 0xFFFFFFFF, 0)

    def test_hash_and_slash_comments_still_strip(self) -> None:
        got = asm.assemble("addi x1, x0, 1  # foo ; bar\naddi x2, x0, 2 // x;y\n")
        self.assertEqual(
            got,
            [
                asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 1),
                asm.enc_i(asm.OPC_OP_IMM, 2, 0, 0, 2),
            ],
        )

    def test_equ_unaffected_by_semicolon_separator(self) -> None:
        got = asm.assemble(".equ FOO, 7\naddi x1, x0, FOO; addi x2, x0, FOO\n")
        self.assertEqual(
            got,
            [
                asm.enc_i(asm.OPC_OP_IMM, 1, 0, 0, 7),
                asm.enc_i(asm.OPC_OP_IMM, 2, 0, 0, 7),
            ],
        )


if __name__ == "__main__":
    unittest.main()
