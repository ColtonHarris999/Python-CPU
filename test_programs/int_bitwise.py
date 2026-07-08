# Tests all integer bitwise and shift operators: &, |, ^, <<, >>
def managed_entry() -> int:
    a = 0b10110100   # 180
    b = 0b01101110   # 110
    c = a & b        # 0b00100100 = 36
    d = a | b        # 0b11111110 = 254
    e = a ^ b        # 0b11011010 = 218
    f = 1 << 7       # 128
    g = 0b11001100 >> 2  # 0b00110011 = 51
    return c + d + e + f + g  # 36 + 254 + 218 + 128 + 51 = 687
