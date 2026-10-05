"""G8: later auto-collections must still preload prune-map word 0.

EVERY_N_RUNS=1 aborts an allocation while a dmem beat can still be in
flight. Skip-clear then started PRELOAD immediately and wrote bitmap
word 0 from that stale rdata, so the five static objects in that word
(TUPLE@0x440, TUPLE@0x480, TUPLE@0x4c0, DICT@0x520, CODE@0x700) were
T_POP'd again (objects RTL=oracle+5). S_GC_ENTER now drains the port
first. The dump oracle checks objects on every collection.
"""


def managed_entry():
    acc = 0
    keep = ["preload-stale-keep"]
    for i in range(80):
        chunk = ["item-number-" + str(i), i, [i, i + 1, i + 2]]
        acc = acc + len(chunk[0]) + chunk[1] + len(chunk[2])
        if i % 4 == 0:
            keep[0] = chunk[0]
        chunk = None
    return acc + len(keep[0])


managed_entry()
