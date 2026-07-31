"""UTF-8 iteration yields characters, not individual encoded bytes."""


def managed_entry():
    two_byte_count = 0
    four_byte_count = 0
    for c in "é":
        two_byte_count += 1
    for c in "😀":
        four_byte_count += 1
    return two_byte_count * 10 + four_byte_count


managed_entry()
