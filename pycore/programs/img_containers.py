def managed_entry():
    a = 1
    b = 2
    c = 3
    lst = [a, b, c]
    lst[1] = 40
    d = {}
    d["x"] = 2
    t = (7, 99)
    return lst[1] + d["x"] + t[1]


managed_entry()
