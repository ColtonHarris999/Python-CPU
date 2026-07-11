# Tests while loop and multiple local variable updates.
# Computes the 10th Fibonacci number iteratively.
# fib(0)=0, fib(1)=1, ..., fib(10)=55
def managed_entry() -> int:
    a = 0
    b = 1
    n = 10
    while n > 0:
        nxt = a + b
        a = b
        b = nxt
        n = n - 1
    return a  # 55
