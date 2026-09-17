"""T5: simple f-string FORMAT_SIMPLE + BUILD_STRING → 1."""


def managed_entry():
    if eval(compile('f"a{1}b"', "<s>", "eval")) == "a1b":
        return 1
    return 0


managed_entry()
