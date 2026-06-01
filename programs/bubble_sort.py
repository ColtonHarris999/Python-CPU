def managed_entry() -> int:
    values = [7, 3, 9, 1, 2]
    n = len(values)
    i = 0
    while i < n:
        j = 0
        while j + 1 < n - i:
            if values[j] > values[j + 1]:
                tmp = values[j]
                values[j] = values[j + 1]
                values[j + 1] = tmp
            j += 1
        i += 1
    return values[0] + values[-1]
