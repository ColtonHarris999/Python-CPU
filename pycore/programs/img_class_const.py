"""M4: class-level constant attribute (WSIZE = 8)."""


class C:
    WSIZE = 8

    def get_wsize(self):
        return self.WSIZE


def managed_entry():
    return C().get_wsize()


managed_entry()
