# Nested loops over a list, the spectral-norm shape without floats.
n = 30
a = []
i = 0
while i < n:
    a.append(i + 1)
    i = i + 1
s = 0
i = 0
while i < n:
    j = 0
    row = 0
    while j < n:
        row = row + a[j] * ((i + 1) * (j + 1))
        j = j + 1
    s = s + row
    i = i + 1
print(s)
