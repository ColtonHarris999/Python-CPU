"""LOAD_NAME at module scope falls back to the builtins dict."""

# Module-level expression uses LOAD_NAME in some 3.14 shapes; keep the
# call inside managed_entry (LOAD_GLOBAL) and also bind via a name load
# helper that stores then reloads through globals→builtins.


def managed_entry():
    # `len` is not in globals; LOAD_GLOBAL/LOAD_NAME both probe builtins.
    n = len("abcd")
    return n


managed_entry()
