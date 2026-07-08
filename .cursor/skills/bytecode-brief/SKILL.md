---
name: bytecode-brief
description: >-
  Brief on a single CPython 3.14 bytecode for PyCore: official semantics plus
  implementation status. Use when the user asks about a specific opcode,
  mentions "bytecode brief", or names an opcode like LOAD_FAST or BINARY_OP.
disable-model-invocation: true
---

# Bytecode Brief

Answer with **only** the template below. No preamble, no closing summary.

## Before writing

1. **CPython 3.14 semantics** — paraphrase the official `dis` docs for this opcode (https://docs.python.org/3.14/library/dis.html). One short paragraph; stay close to the documented stack effect and purpose.
2. **PyCore status** — read, in order:
   - `pycore/targets/pycore.json` → `opcodes.<NAME>`
   - matching row in `pycore/docs/bytecode_support.md`
   - optional: grep the repo for decode/execute handling if status is `execute` or `partial`
3. If the opcode is unknown or not in 3.14, say so in the PyCore section and stop.

## Output template

Copy this structure exactly. Replace `{…}` placeholders; delete lines marked *(optional)* when empty.

```markdown
## `{OPCODE}`

| | |
|---|---|
| **Support** | `{execute \| partial \| strip \| reject \| trap}` |
| **hw_class** | `{REG \| IMM \| CONST \| ALU1 \| ALUN \| PRED \| BRANCH \| FRAME \| OBJECT \| INTERNAL}` |
| **Stack** | `{net stack delta, e.g. +1 / −2 / 0}` *(optional)* |

### CPython 3.14

{One paragraph: what the opcode does, stack operands, and oparg meaning. Plain language; no bullet lists.}

### PyCore

{One paragraph: current support level, whether preprocess rejects or hardware traps, which datapath unit would handle it, and the smallest plausible next step if not fully supported. Reference concrete files or modules only when helpful.}
```

## Style rules

- Exactly two body sections: **CPython 3.14** and **PyCore**.
- Each body section is **one paragraph** (3–5 sentences).
- Do not duplicate the long table from `bytecode_support.md`; synthesize it.
- Use `hw_class` and `support` values from `pycore.json`, not guesses.
- For `BINARY_OP` / `COMPARE_OP`, mention oparg only if the user named a specific oparg.

## Example invocation

User: `bytecode brief: LOAD_FAST`

Agent output:

## `LOAD_FAST`

| | |
|---|---|
| **Support** | `execute` |
| **hw_class** | `REG` |
| **Stack** | `+1` |

### CPython 3.14

…

### PyCore

…
