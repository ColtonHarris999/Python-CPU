# Third-party code in firmware and vendor trees

`planning/compile_plan.md` requires a provenance record for every ported
or vendored compiler source.

| Project | Licence | Path | Revision / branch | What we use | Modifications |
| --- | --- | --- | --- | --- | --- |
| [PyCPython](https://github.com/ColtonHarris999/PyCPython) | PSF-2.0 (`pyproject.toml`) | `vendor/pycpython` (git submodule) | branch `claude/cpython-3-14-compile-frontend-4o4fcz` | Host `compile()` oracle and algorithm reference for the on-device compiler. Package never calls `eval` / `exec` / `compile`. | **None in the submodule.** Device-runnable code is a derived port under `pycore_firmware/compiler/` (not yet present), with per-file provenance headers. |

CPython itself is the semantic oracle PyCPython already matches (Tier 0/1
100% on CPython 3.14.7). PyCore does not vendor CPython C sources.

When a firmware file is ported from PyCPython, add a row here and a
header in that file naming the upstream path and revision.
