"""CALL exception TYPE (G9 row 28) as the only heap producer in the loop."""


def one_exc():
    try:
        raise ValueError("exc-payload-long-enough")
    except ValueError as ex:
        return len(ex.args)


def managed_entry():
    total = 0
    for i in range(800):
        total = total + one_exc()
        total = total + i
    return total


managed_entry()
