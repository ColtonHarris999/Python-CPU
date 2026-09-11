"""set.add — native method table entry 4.

Host path uses CPython ``set.add``. Device seed replaces the body with a
SET_ADD opcode so insert/grow reuse the existing SET_ADD trap. Do not
call ``self.add`` from the rewritten device body.
"""


def set_add(self, value):
    self.add(value)
    return None
