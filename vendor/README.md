# Vendored third-party sources

| Path | Upstream | Role |
| --- | --- | --- |
| `pycpython/` | [ColtonHarris999/PyCPython](https://github.com/ColtonHarris999/PyCPython) (branch `claude/cpython-3-14-compile-frontend-4o4fcz`) | CPython 3.14.7 `compile()` pipeline reimplemented in pure Python. Host-side oracle and algorithm source for the on-device compiler. **Not executed on the hart as-is.** |

Pin and provenance: [`pycore_firmware/THIRD_PARTY.md`](../pycore_firmware/THIRD_PARTY.md).
Integration and the on-device port: [`planning/native_compiler_full_plan.md`](../planning/native_compiler_full_plan.md).

Clone with submodules:

```bash
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```
