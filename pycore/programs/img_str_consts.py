def managed_entry():
    d = {}
    d["short"] = 7
    d["this is a long string key"] = 35
    return d["short"] + d["this is a long string key"]


managed_entry()
