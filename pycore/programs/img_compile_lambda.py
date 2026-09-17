"""T5: compile() lambda call → 7."""


def managed_entry():
    return eval(compile("(lambda x: x + 1)(6)", "<s>", "eval"))


managed_entry()
