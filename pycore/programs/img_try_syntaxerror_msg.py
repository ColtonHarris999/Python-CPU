"""Error reporting via SyntaxError args (F4). Expected: 2."""


def managed_entry():
    try:
        raise SyntaxError("hi")
    except SyntaxError as e:
        return len(e.args[0])


managed_entry()
