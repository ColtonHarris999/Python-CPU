# Compile suite T2: if/elif/else, while and for with break, continue and
# else, augmented assignment, del of a local and of a subscript.
def classify(n):
    if n < 0:
        return "neg"
    elif n == 0:
        return "zero"
    elif n < 10:
        return "small"
    else:
        return "big"


for v in [-3, 0, 7, 42]:
    print(v, classify(v))

total = 0
i = 0
while i < 20:
    i += 1
    if i % 3 == 0:
        continue
    if i > 15:
        break
    total += i
print("while", total, i)

found = -1
for k in range(10):
    if k * k > 30:
        found = k
        break
else:
    found = 99
print("for-break", found)

for k in range(3):
    pass
else:
    print("for-else ran", k)

n = 10
while n > 0:
    n -= 3
else:
    print("while-else", n)

acc = 1
for m in range(1, 6):
    acc *= m
acc -= 20
acc //= 5
acc <<= 2
print("aug", acc)

nums = [5, 6, 7, 8]
del nums[1]
print("del sub", len(nums), nums[1])
grid = 0
for r in range(3):
    for c in range(3):
        if r == c:
            continue
        grid += r * 3 + c
print("nested", grid)
