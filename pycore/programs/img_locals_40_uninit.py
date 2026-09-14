# 40-local function: names x0..x38 are assigned; x39 is a local only because
# it is assigned under `if False`.  Reading it must trap MEM_FAULT (7).
# On main the UNINIT-clear loop stops at 32, so x39 is stale rather than
# UNINIT and this test is red.


def managed_entry():
    x0 = 0
    x1 = 1
    x2 = 2
    x3 = 3
    x4 = 4
    x5 = 5
    x6 = 6
    x7 = 7
    x8 = 8
    x9 = 9
    x10 = 10
    x11 = 11
    x12 = 12
    x13 = 13
    x14 = 14
    x15 = 15
    x16 = 16
    x17 = 17
    x18 = 18
    x19 = 19
    x20 = 20
    x21 = 21
    x22 = 22
    x23 = 23
    x24 = 24
    x25 = 25
    x26 = 26
    x27 = 27
    x28 = 28
    x29 = 29
    x30 = 30
    x31 = 31
    x32 = 32
    x33 = 33
    x34 = 34
    x35 = 35
    x36 = 36
    x37 = 37
    x38 = 38
    if False:
        x39 = 1
    return x39


managed_entry()
