"""ROM BIOS: exec a payload string (compiler_design.md §11.7).

A 1-arg ROM program that ``exec``s source (or a code object) in the
caller's globals. Image tests call ``bios("x = 1 + 2")``; later a boot
entry can point here instead of ``managed_entry``.
"""


def bios(payload):
    exec(payload)
    return None
