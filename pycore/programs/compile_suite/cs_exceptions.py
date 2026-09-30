# Compile suite T4 exceptions: try/except/else/finally, raise, except-as,
# finally on return/break, nested handlers, re-raise.
def safe_div(a, b):
    try:
        if b == 0:
            raise ValueError("zero")
        r = a // b
    except ValueError as e:
        return -1
    else:
        return r
    finally:
        pass


def with_finally(n):
    log = 0
    for i in range(n):
        try:
            if i == 2:
                break
            log += 1
        finally:
            log += 10
    return log


def ret_in_finally():
    try:
        return 1
    finally:
        return 2


def reraise():
    try:
        try:
            raise TypeError("inner")
        except TypeError:
            raise
    except TypeError as e:
        return 7


def call_then_try(xs):
    n = len(xs)
    try:
        raise KeyError("k")
    except KeyError:
        return n + 100


print("div", safe_div(9, 3), safe_div(1, 0))
print("finally", with_finally(5))
print("ret fin", ret_in_finally())
print("reraise", reraise())
print("call try", call_then_try([1, 2]))
caught = 0
for exc in [ValueError, TypeError, KeyError]:
    try:
        raise exc("x")
    except (TypeError, KeyError):
        caught += 10
    except ValueError:
        caught += 1
print("tuple except", caught)
