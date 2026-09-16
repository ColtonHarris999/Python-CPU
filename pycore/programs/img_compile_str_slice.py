"""T4: compile() string slice (compiler_design.md §11.2)."""


def managed_entry():
    s = eval(compile("'abcdef'[1:4]", "<s>", "eval"))
    if s == "bcd":
        return 1
    return 0


managed_entry()
