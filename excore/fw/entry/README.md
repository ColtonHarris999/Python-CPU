# Trap entry

`min.s` and `full.s` are the two firmware builds. `full.s` includes
`list_grow.s`, which still holds reset, dispatch, and the handlers.
P7 splits the jump table into this directory; the C fallbacks land under
`fallback/`.
