def managed_entry() -> int:
    a = 37
    b = -9
    c = 5
    d = 3
    e = 2

    add_v = a + b
    sub_v = a - b
    mul_v = b * c
    floor_v = b // c
    mod_v = b % c
    pow_v = d ** e
    lshift_v = c << e
    rshift_v = b >> e
    and_v = a & 15
    or_v = a | d
    xor_v = a ^ c

    return (
        add_v
        + sub_v
        + mul_v
        + floor_v
        + mod_v
        + pow_v
        + lshift_v
        + rshift_v
        + and_v
        + or_v
        + xor_v
    )
