# Compile suite T5 + T6: lambda, decorators, assert, simple f-strings,
# conditional expressions, chained assignment, `;`, comprehension filters.
double = lambda v: v * 2
print("lambda", double(21), (lambda a, b=1: a - b)(5))


def twice(fn):
    def run(x):
        return fn(fn(x))
    return run


@twice
def inc(x):
    return x + 1


print("decorator", inc(5))
assert inc(0) == 2
ok = 0
try:
    assert 1 == 2, "no"
except AssertionError:
    ok = 1
print("assert", ok)
name = "pc"
n = 3
print(f"hi {name}")
print(f"{n}+{n}={n + n}")
print(f"{name!r}")
x = y = z = 4
print("chained", x + y + z)
p = 1; q = 2; r = p + q
print("semi", r)
sign = "neg" if r < 0 else "pos" if r > 0 else "zero"
print("ternary", sign)
big = [v for v in range(20) if v % 7 == 0]
print("filter", len(big), big[-1])
