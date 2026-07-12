"""Two keys that collide under hash & (slot_count-1); look up both."""

def managed_entry() -> int:
    # 2 pairs → slot_count 4; 0 and 4 both hash to slot 0.
    d = {0: 10, 4: 20}
    a = d[0]
    b = d[4]
    return a + b  # 30
