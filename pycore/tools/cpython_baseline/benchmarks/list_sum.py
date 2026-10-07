# Build a list and sum it. Append plus subscript, the list half of
# pyperformance's fannkuch / spectral traffic, kept inside the PyCore subset.
xs = []
i = 0
while i < 400:
    xs.append(i * 3 + 1)
    i = i + 1
s = 0
i = 0
while i < 400:
    s = s + xs[i]
    i = i + 1
print(s)
