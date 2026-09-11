"""damerau min([...]+[...]) shape after BINARY_SLICE tooling.

PyBGL ``damerau_levenshtein_distance_naive`` does
``1 + min([rec1, rec2, rec3] + ([rec4] if swap else []))``.
"""


def managed_entry():
    take = 1
    d = min([3, 1, 2] + ([4] if take else []))
    return 111 + d


managed_entry()
