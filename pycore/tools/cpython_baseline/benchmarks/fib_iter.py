# Iterative Fibonacci in a loop. Calls, integer add, a small frame.
def fib(n):
    a = 0
    b = 1
    i = 0
    while i < n:
        c = a + b
        a = b
        b = c
        i = i + 1
    return a


s = 0
i = 0
while i < 200:
    s = s + fib(18)
    i = i + 1
print(s)
