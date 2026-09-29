# Compile suite T3 + closures: defaults, *args, keyword-only, **kwargs,
# keyword calls, recursion, globals, nested functions and closures.
def area(w, h=2):
    return w * h


def span(first, *rest, scale=1, **opts):
    n = first
    for r in rest:
        n += r
    return n * scale + len(opts)


def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


counter = 0


def bump(by=1):
    global counter
    counter += by
    return counter


def make_adder(k):
    def add(x):
        return x + k
    return add


def make_acc():
    total = 0

    def acc(v):
        nonlocal_total = total + v
        return nonlocal_total
    return acc


print("defaults", area(3), area(3, 4), area(h=5, w=2))
print("varargs", span(1), span(1, 2, 3), span(1, 2, scale=10))
print("kwargs", span(1, a=1, b=2), span(2, 3, scale=2, z=0))
print("fib", fib(15))
bump()
bump(5)
print("global", counter)
add7 = make_adder(7)
print("closure", add7(3), make_adder(-1)(1))
print("closure2", make_acc()(5))
