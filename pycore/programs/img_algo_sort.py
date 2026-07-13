# In-place bubble sort over a small LIST — algorithmic workload covering
# nested loops, COMPARE_OP, STORE_SUBSCR, and subscript reads.

def sort4(a0, a1, a2, a3):
    data = [a0, a1, a2, a3]
    i = 0
    while i < 3:
        j = 0
        while j < 3 - i:
            left = data[j]
            right = data[j + 1]
            if left > right:
                data[j] = right
                data[j + 1] = left
            j = j + 1
        i = i + 1
    return data[0] + data[1] * 10 + data[2] * 100 + data[3] * 1000


def managed_entry():
    return sort4(5, 1, 4, 2)


managed_entry()
