"""A2: exec(compile(T1–T3 src)) globals match CPython (compiler_design.md J).

Module-level ``y`` is stored by the compiled program and read back here.
Host ``exec`` stand-in shares the live globals dict so STORE_NAME is visible.
Expected result: 7.

Single-core dicts cannot grow (PY_TRAP_DICT_GROW). Pre-bind every name
the compiled program STOREs so exec overwrites existing module keys.
"""

SRC = """\
def add(a, b):
    return a + b
n = 3
s = 0
i = 0
while i < n:
    s = s + i
    i = i + 1
if s == 3:
    s = s + 1
else:
    s = 0
xs = [1, 2]
for x in xs:
    s = add(s, x)
y = s
"""

add = None
n = None
s = None
i = None
xs = None
x = None
y = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return y


managed_entry()
