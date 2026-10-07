# Integer dict fill and lookup. Hash randomization is pinned by the runner
# (PYTHONHASHSEED=0) so the miss counts stay put across runs.
d = {}
i = 0
while i < 300:
    d[i] = i * i
    i = i + 1
s = 0
i = 0
while i < 300:
    s = s + d[i]
    i = i + 1
print(s)
