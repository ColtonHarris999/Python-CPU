# Tight loop: the interpreter-overhead floor. No calls, no containers.
i = 0
s = 0
while i < 4000:
    s = s + i
    i = i + 1
print(s)
