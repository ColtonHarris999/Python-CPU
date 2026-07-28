# Exercises the COPY opcode via a module-level chained assignment.
#
# `x = y = 5` compiles to LOAD_SMALL_INT 5; COPY 1; STORE_NAME x; STORE_NAME y.
# COPY duplicates the value so it can feed both global stores; the duplicated
# entry is the one stored into `x`.  managed_entry reads `x` back, so a COPY
# that pushed the wrong slot (or a bad tag) surfaces as a wrong entry return.

x = y = 5


def managed_entry():
    return x


managed_entry()
