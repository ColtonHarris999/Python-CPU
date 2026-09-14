# Watermark-straddling call/return ×1000. pad() builds a deep stack so leaf()
# spills once (with RF_SPILL_HYST); subsequent leaf calls must not re-spill
# the same window. Return value is 1000; spill-count golden is checked via
# +CHECK_RF_SPILL_COUNT=33 (one burst of HYST+1; later leaf() calls must
# not re-spill).


def leaf():
    return 1


def pad(n):
    if n <= 0:
        s = 0
        i = 0
        while i < 1000:
            s = s + leaf()
            i = i + 1
        return s
    return pad(n - 1)


def managed_entry():
    return pad(50)


managed_entry()
