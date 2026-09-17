"""T5: compile() assert that holds, then 1."""


def managed_entry():
    exec(compile("assert 1\n", "<s>", "exec"))
    return 1


managed_entry()
