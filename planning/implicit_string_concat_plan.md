# Implicit string-literal concatenation

Status: **plan, not started.**

Audience: firmware-compiler agent.

Parent evaluation:
[`cpython_baseline_bytecode.md`](cpython_baseline_bytecode.md).

This is the only change required before every program in the measured
CPython baseline suite compiles on the device. It adds no opcode, no
trap, and no RTL.

## What is wrong

CPython joins string literals that sit next to each other in one
expression, with only whitespace between them:

```python
s = "ab" "cd"          # "abcd"
ALU = (
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG"
    "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
)
```

The lexer already drops newlines while parentheses, brackets, or braces
are open (`lexer.py`, `paren > 0`), so the parser sees
`(` STRING STRING `)`. `_pyc_parse_expr` only accepts `TOK_STRING` when
`want == 1` (it is expecting an operand). The second literal arrives
with `want == 0` and is left for the closer, which reports
`unmatched bracket`. The same pair on one line, outside parentheses,
falls out of the expression and the statement parser reports
`unexpected input after statement`.

`fasta.py` and `knucleotide.py` are the two baseline programs that do
this. Both `SyntaxError` on the device compiler. Joining the pieces by
hand makes the host stand-in match CPython (fasta at N=30 prints
`23258`; knucleotide at N=200 prints `1827507`). The pieces are the
published ALU sequence; the joined value is one string of a few hundred
characters.

## What to implement

Join adjacent `TOK_STRING` tokens into one `Constant` while parsing the
expression. Codegen then emits one `LOAD_CONST`, which is what CPython
emits after its own fold.

Do this in `_pyc_parse_expr` (`pycore_firmware/compiler/parser.py`),
next to the existing `kind == TOK_STRING` arm:

- When `want == 0` and the next token is `TOK_STRING`, and the operand
  just pushed was itself a string literal token, decode the new token
  with `_pyc_parse_string` and append it to that constant's `nd_obj`.
  Stay at `want == 0`. Repeat for a third literal, and so on.
- Remember that the previous operand came from a string *token*. A
  string constant that is only the result of grouping must not join.
  CPython rejects `("a") "b"`. Clearing the flag on `)` (and on any
  other atom, operator, or reduce) is the check. `"a" "b"` and
  `("a" "b")` join. `("a") "b"` stays a syntax error.
- A string token after a non-string atom (`1 "a"`, `x "a"`) is a
  syntax error, with a message that names the adjacent literal. The
  current `unmatched bracket` text hides the cause.

Decode each piece with the existing `_pyc_parse_string`, so escapes and
quote styles are already handled and then the decoded bodies are
concatenated. `"a\n" "b"` is the two characters newline and `b`.
Mixed quotes (`"a" 'b'`) join. A raw prefix applies to that piece only
(`r"\n" "b"` keeps the backslash).

The join happens at the token, before operators reduce. `"a" "b" + "c"`
is `("ab") + "c"`. The existing codegen fold of `str +` (compiler.md
§11.3) then turns the addition into one constant. The token join has to
happen first so that `"a" "b"` is not a second statement.

## What not to emit

`BUILD_STRING` is the wrong opcode. Its hart ceiling is every piece a
`SHORT_STR` and the total length ≤ 15 (`bytecode_support.md`). The ALU
literal is far past that, and a `BUILD_STRING` of it would `TYPE`-trap
at run time. One `LOAD_CONST` of the joined string is the CPython
shape, and `LOAD_CONST` of a `LONG_STR` already indexes (`SA_CHAR_AT`,
`ord`, `len`).

Do not add an opcode, a `pycore.json` row, or an RTL change.

Leave these alone. They are not this bug:

- f-strings (`f"a" "b"` is legal CPython and is not in the baseline
  suite). A `TOK_STRING` after an f-string end can stay a syntax error
  until f-strings grow that case.
- bytes literals. `b"a" b"b"` still hits the existing bytes rejection
  on the first token.
- explicit `"a" + "b"`. Already folded in codegen.
- the excore / container-accelerator work. `fasta` and `knucleotide`
  still append and grow dicts through the traps that work owns.

## Device behavior of the long constant

The joined ALU string is one constant of a few hundred Latin-1
characters. The parser builds it with ordinary string concatenation
while `compile()` runs, so on the hart that concatenation is the
existing `SA_CONCAT` path, and `_bi_code_new` stores the resulting
string in `co_consts`. `LOAD_CONST` pushes that `LONG_STR`. The
baseline then indexes it (`ALU[i]`, `ord(ALU[i])`).

The host stand-in concatenates with CPython `str +` and will not show
an `SA_CONCAT` bug. A device run of a string longer than 15 characters
is the check that the constant survived code-object assembly.

## Tests

Host stand-in first (`load_rom_firmware_callables()["compile"]` in
`pycore/tests/test_compiler_differential.py`). Add expressions and
statements, compared by result the way the rest of that file does:

| Source | Result |
| --- | --- |
| `"ab" "cd"` | `"abcd"` |
| `"a" 'b' "c"` | `"abc"` |
| `"a\n" "b"` | `"a\nb"` |
| `r"\n" "b"` | `"\\nb"` (backslash, n, b) |
| `("ab"\n "cd")` | `"abcd"` |
| `"ab" "cd" + "e"` | `"abcde"` |
| `s = ("ab" "cd")` then `len(s)` | `4` |
| `("a") "b"` | `SyntaxError` |
| `1 "a"` | `SyntaxError` |

Then the two baseline files, unmodified, at a reduced size so the
stand-in's step cap is irrelevant. Compare stdout with CPython:

- `fasta.py` with `N = 30` prints `23258`.
- `knucleotide.py` with `N = 200` prints `1827507`.

Full `N = 5000` and `N = 8000` match too; they are just more iterations
of the same bytecode. The published checksums (`516277`, `73307453`)
are the full-size check when someone runs them.

Device, once the host differential is green. `make run-file
RUN_SOURCE=...` on:

1. A few-line program whose joined literal is longer than 15
   characters, printing `len` and `ord` of a character past index 15.
   That is the `LONG_STR` constant.
2. `fasta.py` and `knucleotide.py` with the reduced `N` above, stdout
   against CPython.

The full research sizes are a long simulator run (the baseline doc's
cycle table is why). They are not the gate for this parser change.
After the reduced device run matches, delete the
`compile_limitations.md` §4 row this plan added, and drop the
"adjacent string literals" phrase from the grammar cell in
`planning/master_plan.md`.

## Files

| File | Change |
| --- | --- |
| `pycore_firmware/compiler/parser.py` | Join adjacent `TOK_STRING` tokens in `_pyc_parse_expr` |
| `pycore/tests/test_compiler_differential.py` | The cases in the table above |
| `pycore/docs/compile_limitations.md` | Remove the §4 row when the tests pass |
| `planning/master_plan.md` | Remove the phrase from the grammar cell when the tests pass |

`tables.py` does not change. No `pycore.json` edit. No image fixture is
required beyond `make run-file` on the two programs; add an
`img_compile_*` program only if the differential suite's device job
needs a checked-in source for the long constant.
