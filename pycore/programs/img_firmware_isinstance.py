"""ROM isinstance / issubclass via __class__ / __base__ specials.

# pycore-inject: SEED_TYPE Base
# pycore-inject: SEED_TYPE Child base=Base
# pycore-inject: SEED_TYPE Other
# pycore-inject: SEED_INSTANCE o type=Child slots=4
"""


def managed_entry():
    total = 0
    if isinstance(o, Child):
        total += 1
    if isinstance(o, Base):
        total += 2
    if not isinstance(o, Other):
        total += 4
    if issubclass(Child, Base):
        total += 8
    if issubclass(Child, Child):
        total += 16
    if not issubclass(Base, Child):
        total += 32
    if not issubclass(Other, Base):
        total += 64
    return total


managed_entry()
