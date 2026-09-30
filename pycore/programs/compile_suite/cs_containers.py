# Compile suite T4 containers: displays, comprehensions with a filter,
# subscripts, negative indexes, display slices, native methods, builtins.
squares = [x * x for x in range(8)]
evens = [x for x in squares if x % 2 == 0]
print("listcomp", len(squares), evens[2], squares[-1])
seen = {c for c in "banana"}
print("setcomp", len(seen), "n" in seen)
index = {w: len(w) for w in ["ab", "cde", "f"] if len(w) > 1}
print("dictcomp", len(index), index["cde"])
nums = [4, 1, 3]
nums.append(2)
nums.extend([9, 0])
last = nums.pop()
# Native max() is the two-argument form only.
print("list ops", len(nums), last, sum(nums), min(nums), max(nums[0], nums[-1]))
print("sorted", sorted(nums)[0], sorted(nums)[-1])
d = {"a": 1}
d["b"] = 2
d.update({"c": 3})
print("dict ops", d.get("a"), d.get("z", 0), len(d.keys()), sum(d.values()))
total = 0
for k, v in d.items():
    total += v
print("items", total)
pairs = list(zip([1, 2, 3], [10, 20, 30]))
print("zip", len(pairs), pairs[1][1])
for i, ch in enumerate("xyz"):
    if ch == "z":
        print("enumerate", i)
print("display slice", [10, 20, 30, 40][1:3][1], (1, 2, 3)[-2])
t = (5, 6, 7)
a, b, c = t
print("unpack", a + b + c)
s = set()
s.add(3)
s.add(3)
print("set", len(s), "join", "-".join(["a", "b"]))
